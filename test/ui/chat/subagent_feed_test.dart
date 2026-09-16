import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/subagent_feed.dart';

import '../chat_page_test.dart' show FakeChatGateway;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('acquire dedupes per childSessionId; release closes at zero refs',
      () async {
    final gateway = FakeChatGateway();
    final feed = SubagentFeed(gateway: gateway);
    feed.acquire('c1');
    feed.acquire('c1'); // second consumer, same subscription
    feed.acquire('c2');
    await pumpEventQueue();
    expect(gateway.subscribedSessions, ['c1', 'c2']);
    expect(gateway.closedSessions, isEmpty);

    // First release only drops the refcount.
    feed.release('c1');
    expect(gateway.closedSessions, isEmpty);
    // Last release closes the shared subscription.
    feed.release('c1');
    await pumpEventQueue();
    expect(gateway.closedSessions, ['c1']);
    // c2 stays subscribed until its own release.
    feed.release('c2');
    await pumpEventQueue();
    expect(gateway.closedSessions, ['c1', 'c2']);
    feed.dispose();
  });

  test('release of an unknown id is a no-op; childState needs a live handle',
      () async {
    final gateway = FakeChatGateway();
    final feed = SubagentFeed(gateway: gateway);
    feed.release('ghost');
    expect(feed.childState('ghost'), isNull);
    feed.acquire('c1');
    await pumpEventQueue();
    expect(feed.childState('c1'), same(gateway.state));
    feed.dispose();
    expect(gateway.closedSessions, ['c1']);
  });

  test('terminal hysteresis: replayed running within the window keeps the '
      'terminal view; persisted running is believed', () async {
    final gateway = FakeChatGateway();
    final feed = SubagentFeed(
      gateway: gateway,
      regressionHysteresis: const Duration(milliseconds: 80),
    );
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'subagent',
        'childSessionId': 'c1',
        'status': 'success',
        'summaryText': 't',
      },
    ]);
    feed.observe(gateway.state);

    // Replay inside the window: the consumer keeps seeing success.
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'subagent',
        'childSessionId': 'c1',
        'status': 'running',
        'summaryText': 't',
      },
    ]);
    expect(feed.effectiveStatus('c1', 'running'), 'success');

    // Persisted past the window: the running report is believed.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'subagent',
        'childSessionId': 'c1',
        'status': 'running',
        'summaryText': 't',
      },
    ]);
    expect(feed.effectiveStatus('c1', 'running'), 'running');
    feed.dispose();
  });
}
