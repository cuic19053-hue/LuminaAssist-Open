import localUnitTest from './LocalUnit.test';
import engineUnitTest from './EngineUnit.test';

export default function testsuite() {
  localUnitTest();
  engineUnitTest();
}