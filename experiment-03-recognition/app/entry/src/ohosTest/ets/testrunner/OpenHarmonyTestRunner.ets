import { Hypium } from '@ohos/hypium';
import TestRunner from '@ohos.application.testRunner';
import testsuite from '../test/List.test';

export default class OpenHarmonyTestRunner implements TestRunner {
  onRun(): void {
    Hypium.hypiumTest(0, 0, testsuite);
  }

  onPrepare(): void {
  }
}
