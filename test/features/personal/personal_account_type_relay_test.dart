import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/personal/data/account_type_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a choice is kept on the device and marked for the other devices', () async {
    PersonalAccountTypeStore.now = () => 100;
    await PersonalAccountTypeStore.save('a1', 'savings');
    expect(await PersonalAccountTypeStore.load(), {'a1': 'savings'});
    expect(await PersonalAccountTypeStore.takePending(), isTrue);
    expect(await PersonalAccountTypeStore.takePending(), isFalse);
    expect((await PersonalAccountTypeStore.snapshot())['types'], {
      'a1': {'t': 'savings', 'at': 100},
    });
  });

  test('a fresh install takes the other device types; newer choice wins', () async {
    // Reinstall / new phone: nothing here yet.
    expect(await PersonalAccountTypeStore.merge({
      'types': {
        'a1': {'t': 'savings', 'at': 100},
        'a2': {'t': 'checking', 'at': 100},
      },
    }), isTrue);
    expect(await PersonalAccountTypeStore.load(), {'a1': 'savings', 'a2': 'checking'});
    // An older snapshot never overrides a later choice made here.
    PersonalAccountTypeStore.now = () => 500;
    await PersonalAccountTypeStore.save('a1', 'checking');
    expect(await PersonalAccountTypeStore.merge({
      'types': {'a1': {'t': 'savings', 'at': 200}},
    }), isFalse);
    expect((await PersonalAccountTypeStore.load())['a1'], 'checking');
    // A later choice from the other device does.
    expect(await PersonalAccountTypeStore.merge({
      'types': {'a1': {'t': 'savings', 'at': 900}},
    }), isTrue);
    expect((await PersonalAccountTypeStore.load())['a1'], 'savings');
  });

  test('junk is ignored and the first-run request happens once', () async {
    expect(await PersonalAccountTypeStore.merge({'types': {'x': {'t': 'gold'}}}), isFalse);
    expect(await PersonalAccountTypeStore.merge({'types': 3}), isFalse);
    expect(await PersonalAccountTypeStore.takeFirstRequest(), isTrue);
    expect(await PersonalAccountTypeStore.takeFirstRequest(), isFalse);
    await PersonalAccountTypeStore.clearRequested();
    expect(await PersonalAccountTypeStore.takeFirstRequest(), isTrue);
  });

  test('legacy map written by older builds still loads', () async {
    SharedPreferences.setMockInitialValues({
      PersonalAccountTypeStore.typesKey: '{"old":"savings"}',
    });
    expect(await PersonalAccountTypeStore.load(), {'old': 'savings'});
    expect((await PersonalAccountTypeStore.snapshot())['types'], {
      'old': {'t': 'savings', 'at': 0},
    });
  });
}
