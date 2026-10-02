"""隐私数据脱敏过滤器 (Data Masking)"""
import re
import logging

logger = logging.getLogger("lumina.backend.privacy")

class PrivacyFilter:
    """提供基于正则的轻量级隐私数据掩码能力，保护视障老人隐私数据不泄露给云端大模型。"""
    
    # 手机号正则：1开头，第二位3-9，后续9位数字
    PHONE_PATTERN = re.compile(r'(1[3-9]\d)(\d{4})(\d{4})')
    
    # 身份证正则：18位身份证（简单规则）
    # 前6位区划，中间8位生日，后4位顺序+校验码
    ID_CARD_PATTERN = re.compile(r'([1-9]\d{5})(\d{8})(\d{3}[0-9Xx])')
    
    # 银行卡正则：连续的16到19位数字
    # 过于简单的纯数字容易误伤，所以加了前后边界
    BANK_CARD_PATTERN = re.compile(r'(?<!\d)(\d{4})\d{8,11}(\d{4})(?!\d)')

    @classmethod
    def mask_text(cls, text: str) -> str:
        if not text:
            return text
            
        masked_text = text
        
        # 掩码手机号：138****1234
        if cls.PHONE_PATTERN.search(masked_text):
            masked_text = cls.PHONE_PATTERN.sub(r'\1****\3', masked_text)
            
        # 掩码身份证：310105********1234
        if cls.ID_CARD_PATTERN.search(masked_text):
            masked_text = cls.ID_CARD_PATTERN.sub(r'\1********\3', masked_text)
            
        # 掩码银行卡：6222********1234
        if cls.BANK_CARD_PATTERN.search(masked_text):
            masked_text = cls.BANK_CARD_PATTERN.sub(r'\1********\2', masked_text)
            
        return masked_text
