import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { CHAR_DATA, resolveCharName } from '../main/ets/services/CharData';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });

    it('charData_内置示例显示名映射', 0, () => {
      // 内置示例 zhala_2 应映射为 Zara（role 末段匹配，兼容不同 group）
      expect(resolveCharName('zhala_2/zhala_2', 'zhala_2')).assertEqual('Zara');
    });

    it('charData_完整路径精确匹配', 0, () => {
      // 与 charData.js 完全一致的路径应精确命中
      expect(resolveCharName('Azue Lane(JP)/zhala_2', 'zhala_2')).assertEqual('Zara');
    });

    it('charData_无映射时返回空串', 0, () => {
      expect(resolveCharName('unknown/unknown', 'unknown')).assertEqual('');
    });

    it('charData_映射表非空且完整', 0, () => {
      let keys = Object.keys(CHAR_DATA);
      expect(keys.length).assertLarger(0);
      for (let key of keys) {
        expect(CHAR_DATA[key].length).assertLargerOrEqual(1);
      }
    });
  });
}
