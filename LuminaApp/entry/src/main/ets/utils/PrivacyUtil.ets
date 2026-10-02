/**
 * @file PrivacyUtil.ets
 * @module utils
 * @description 脱敏工具类，用于在发送给云端前过滤身份证号、银行卡号等敏感信息。
 */

export class PrivacyUtil {
  /**
   * 掩码用户的敏感信息（身份证、银行卡）
   */
  public static maskSensitiveInfo(text: string): string {
    if (!text || text.length === 0) {
      return text;
    }

    let masked = text;

    // 1. 身份证号脱敏: 18位，最后一位可能为X/x
    // 例如：110101195012312345 -> 110101********2345
    const idCardRegex = /(\d{6})\d{8}(\d{3}[0-9Xx])/g;
    masked = masked.replace(idCardRegex, '$1********$2');

    // 2. 银行卡号等连续长数字防骗: 一般16-19位纯数字
    // 为匹配用例 TC-U4-02："卡号 6222021234567890123" -> "***"
    const longDigitsRegex = /\d{16,19}/g;
    masked = masked.replace(longDigitsRegex, '***');

    return masked;
  }
}
