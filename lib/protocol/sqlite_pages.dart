import 'dart:convert';
import 'dart:typed_data';

/// One byte-range read of a desktop file — the injected seam over the file
/// channel's `readFileRange` (widget-free: the transport-side call is
/// composed in DeviceSession, this layer never imports the channel).
///
/// Success answers the bytes the desktop returned (empty/short only at EOF,
/// which the page reader treats as a truncated index); ANY channel-level
/// problem — timeout, bridge swing, missing method — is THROWN. Resolvers
/// classify a throw as TRANSIENT (do not cache: retry later) and a
/// short/garbled answer as DETERMINISTIC (cache the null).
typedef SqliteRangeRead = Future<Uint8List> Function(
  String path,
  int offset,
  int length,
);

/// A deterministic parse/schema problem: the file is not the index we can
/// read, and re-reading it buys nothing.
class SqliteFormatError implements Exception {
  const SqliteFormatError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The SQLite file-header change counter (offset 24, big-endian, 4 bytes):
/// SQLite bumps it on every committed write transaction. Resolvers compare
/// it before and after a page walk to spot a checkpoint writing pages
/// underneath the read (the main file is read without taking a lock).
int changeCounterOf(Uint8List header) {
  if (header.length < 28) {
    throw const SqliteFormatError('truncated header');
  }
  return (header[24] << 24) |
      (header[25] << 16) |
      (header[26] << 8) |
      header[27];
}

/// Minimal read-only SQLite table-b-tree reader — only what the desktop
/// index reads need. File format reference: sqlite.org/fileformat2.html.
///
/// Reads exactly the pages it walks: 100-byte header → page 1
/// (`sqlite_master`) → each target table's root page and child pages.
/// Overflow chains are followed for both `sqlite_master.sql` rows and leaf
/// data rows (a CREATE statement or a long root path can exceed one page).
class SqlitePageReader {
  SqlitePageReader._(
    this._path,
    this._read,
    this._pageSize,
    this._usable,
    this._pageCount,
    this.header,
  );

  /// SQLite file header size; page 1's b-tree header starts right after it.
  static const headerBytes = 100;

  static const _magic = 'SQLite format 3\u0000';

  /// Safety bound on corrupt page numbers when the header carries no page
  /// count; the count is normally authoritative.
  static const _pageLimit = 1 << 26;

  final String _path;
  final SqliteRangeRead _read;
  final int _pageSize;

  /// Page size minus the reserved area at the end of every page — the
  /// usable payload region the b-tree actually addresses.
  final int _usable;

  /// Database size in pages from the header (0 = unknown/ignored).
  final int _pageCount;

  /// The 100-byte file header [open] read (the change counter lives here).
  final Uint8List header;

  int _pagesRead = 0;

  /// Pages touched by b-tree walks since [open] — the page-budget guard
  /// reads this (asserting a resolver never walks the whole database).
  int get pagesRead => _pagesRead;

  static Future<SqlitePageReader> open(
    String path,
    SqliteRangeRead read,
  ) async {
    final header = await read(path, 0, headerBytes);
    if (header.length < headerBytes) {
      throw const SqliteFormatError('truncated header');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic.codeUnitAt(i)) {
        throw const SqliteFormatError('bad magic');
      }
    }
    // Offset 16: page size, big-endian; the value 1 encodes 65536.
    var pageSize = (header[16] << 8) | header[17];
    if (pageSize == 1) pageSize = 65536;
    if (pageSize < 512 || pageSize > 65536 || (pageSize & (pageSize - 1)) != 0) {
      throw SqliteFormatError('bad page size $pageSize');
    }
    // Offset 20: reserved bytes per page; usable = page size - reserved.
    final usable = pageSize - header[20];
    if (usable < 480) {
      // SQLite's own minimum (fileformat2 §1.3).
      throw SqliteFormatError('bad usable size $usable');
    }
    final pageCount = (header[28] << 24) |
        (header[29] << 16) |
        (header[30] << 8) |
        header[31];
    return SqlitePageReader._(
      path,
      read,
      pageSize,
      usable,
      pageCount,
      header,
    );
  }

  /// Walks a table b-tree from [rootPage] and answers every leaf record.
  /// Interior table pages (0x05) recurse into their child pointers plus the
  /// right-most child at header offset 8; leaves (0x0D) decode their cells.
  Future<List<List<Object?>>> scanTable(int rootPage) async {
    final rows = <List<Object?>>[];
    final visited = <int>{};
    Future<void> visit(int pageNo) async {
      if (!visited.add(pageNo)) {
        throw SqliteFormatError('b-tree cycle at page $pageNo');
      }
      final page = await _page(pageNo);
      // Page 1 carries the 100-byte file header before its b-tree header.
      final h = pageNo == 1 ? headerBytes : 0;
      if (h + 12 > _usable) throw const SqliteFormatError('short page header');
      final type = page[h];
      final headerSize = switch (type) {
        0x05 => 12, // interior table b-tree
        0x0D => 8, // leaf table b-tree
        _ => throw SqliteFormatError(
            'page $pageNo has b-tree type 0x${type.toRadixString(16)}'),
      };
      final cellCount = (page[h + 3] << 8) | page[h + 4];
      final pointers = h + headerSize;
      if (pointers + cellCount * 2 > _usable) {
        throw const SqliteFormatError('cell pointer array past page');
      }
      for (var i = 0; i < cellCount; i++) {
        final at = pointers + i * 2;
        final cell = (page[at] << 8) | page[at + 1];
        if (cell + 4 > _usable) {
          throw const SqliteFormatError('cell offset past page');
        }
        if (type == 0x05) {
          // Interior table cell: 4-byte left child page number + rowid key.
          await visit(_be32(page, cell));
        } else {
          rows.add(_record(await _leafPayload(page, cell)));
        }
      }
      if (type == 0x05) {
        // Right-most child pointer lives in the page header.
        await visit(_be32(page, h + 8));
      }
    }

    await visit(rootPage);
    return rows;
  }

  Future<Uint8List> _page(int pageNo) async {
    if (pageNo <= 0) {
      throw SqliteFormatError('bad page number $pageNo');
    }
    final limit = _pageCount > 0 ? _pageCount : _pageLimit;
    if (pageNo > limit) {
      throw SqliteFormatError('page $pageNo past database end ($limit)');
    }
    _pagesRead++;
    final bytes = await _read(_path, (pageNo - 1) * _pageSize, _pageSize);
    if (bytes.length < _usable) {
      // Short read inside the database: the index is truncated (a transient
      // channel error would have thrown from the seam instead).
      throw SqliteFormatError('short read at page $pageNo '
          '(${bytes.length}/$_usable)');
    }
    return bytes;
  }

  /// One table-leaf cell → its record payload: varint payload length,
  /// varint rowid, then the local payload (plus a 4-byte overflow pointer
  /// when the payload exceeds the local size). The overflow chain is
  /// followed until the declared payload length is assembled.
  Future<Uint8List> _leafPayload(Uint8List page, int cell) async {
    final total = _varint(page, cell, limit: _usable);
    final afterLength = cell + total.length;
    final rowid = _varint(page, afterLength, limit: _usable);
    final start = afterLength + rowid.length;
    final local = _localPayloadSize(total.value);
    final tail = local < total.value ? 4 : 0;
    if (start + local + tail > _usable) {
      throw const SqliteFormatError('leaf payload past page');
    }
    if (local == total.value) {
      return Uint8List.sublistView(page, start, start + local);
    }
    var overflow = _be32(page, start + local);
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(page, start, start + local));
    var remaining = total.value - local;
    final seen = <int>{};
    while (remaining > 0) {
      if (overflow == 0 || !seen.add(overflow)) {
        throw const SqliteFormatError('broken overflow chain');
      }
      final next = await _page(overflow);
      final chunk = remaining < _usable - 4 ? remaining : _usable - 4;
      out.add(Uint8List.sublistView(next, 4, 4 + chunk));
      remaining -= chunk;
      overflow = _be32(next, 0);
    }
    return out.takeBytes();
  }

  /// How much of a table-leaf payload lives on the page itself
  /// (fileformat2 §2.3.1, table b-tree fractions: max 64, min 32,
  /// leaf 32):
  ///   maxLocal = usable - 35
  ///   minLocal = ((usable - 12) * 32 / 255) - 23
  int _localPayloadSize(int total) {
    final maxLocal = _usable - 35;
    if (total <= maxLocal) return total;
    final minLocal = ((_usable - 12) * 32) ~/ 255 - 23;
    var local = minLocal + (total - minLocal) % (_usable - 4);
    if (local > maxLocal) local = minLocal;
    return local;
  }

  /// Record format: header-size varint (includes itself), serial-type
  /// varints, then the body values in order.
  static List<Object?> _record(Uint8List payload) {
    final header = _varint(payload, 0);
    final headerEnd = header.value;
    if (headerEnd < header.length || headerEnd > payload.length) {
      throw const SqliteFormatError('bad record header length');
    }
    final types = <int>[];
    var at = header.length;
    while (at < headerEnd) {
      final type = _varint(payload, at, limit: headerEnd);
      at += type.length;
      types.add(type.value);
    }
    if (at != headerEnd) {
      throw const SqliteFormatError('record header overflow');
    }
    final values = <Object?>[];
    var data = headerEnd;
    for (final type in types) {
      switch (type) {
        case 0:
          values.add(null);
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
        case 6:
          final size = const [0, 1, 2, 3, 4, 6, 8][type];
          values.add(_int(payload, data, size));
          data += size;
        case 7:
          if (data + 8 > payload.length) {
            throw const SqliteFormatError('record value past payload');
          }
          values.add(
            ByteData.sublistView(payload, data, data + 8).getFloat64(0),
          );
          data += 8;
        case 8:
          values.add(0);
        case 9:
          values.add(1);
        default:
          final text = type.isOdd;
          final size = text ? (type - 13) ~/ 2 : (type - 12) ~/ 2;
          if (size < 0 || data + size > payload.length) {
            throw const SqliteFormatError('record value past payload');
          }
          final bytes = Uint8List.sublistView(payload, data, data + size);
          if (text) {
            try {
              values.add(utf8.decode(bytes));
            } on FormatException {
              throw const SqliteFormatError('record text is not utf-8');
            }
          } else {
            values.add(bytes);
          }
          data += size;
      }
    }
    if (data > payload.length) {
      throw const SqliteFormatError('record body past payload');
    }
    return values;
  }

  /// Big-endian signed integer of [size] bytes (serial types 1-6).
  static int _int(Uint8List bytes, int offset, int size) {
    if (offset + size > bytes.length) {
      throw const SqliteFormatError('record integer past payload');
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return switch (size) {
      1 => value >= 0x80 ? value - 0x100 : value,
      2 => value >= 0x8000 ? value - 0x10000 : value,
      3 => value >= 0x800000 ? value - 0x1000000 : value,
      4 => value >= 0x80000000 ? value - 0x100000000 : value,
      6 => value >= 0x800000000000 ? value - 0x1000000000000 : value,
      // Dart ints are 64-bit two's complement: the wraps ARE the sign.
      _ => value,
    };
  }

  /// SQLite varint: 1-9 bytes, 7 bits each, the 9th byte contributes 8.
  static ({int value, int length}) _varint(
    Uint8List bytes,
    int offset, {
    int? limit,
  }) {
    final end = limit ?? bytes.length;
    var value = 0;
    for (var i = 0; i < 9; i++) {
      final at = offset + i;
      if (at >= end || at >= bytes.length) {
        throw const SqliteFormatError('varint past page');
      }
      final byte = bytes[at];
      if (i == 8) {
        value = (value << 8) | byte;
        return (value: value, length: 9);
      }
      value = (value << 7) | (byte & 0x7f);
      if (byte & 0x80 == 0) return (value: value, length: i + 1);
    }
    throw const SqliteFormatError('varint too long');
  }

  static int _be32(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) {
      throw const SqliteFormatError('u32 past page');
    }
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }
}
