import zipfile
import xml.etree.ElementTree as ET

doc_path = r"d:\c4.ai.huawei\docs\光语助手需求文档.docx"
out_path = r"d:\c4.ai.huawei\docs\extracted_requirement.txt"

with zipfile.ZipFile(doc_path) as z:
    xml_content = z.read('word/document.xml')

root = ET.fromstring(xml_content)
namespaces = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}

text_list = []
for p in root.findall('.//w:p', namespaces):
    p_text = ''.join([node.text for node in p.findall('.//w:t', namespaces) if node.text])
    if p_text.strip():
        text_list.append(p_text)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(text_list))

print(f"Extracted {len(text_list)} lines to {out_path}")
