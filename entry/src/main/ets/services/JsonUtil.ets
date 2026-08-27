/**
 * JS 风格 JSON 容错工具。
 * 手游解包入口 json 常见尾随逗号（如 "textures": ["a.png",]），
 * 标准 JSON.parse 会失败，先剔除尾随逗号再解析。
 */

/** 剔除数组/对象末尾的尾随逗号（"a",] → "a"] / }, → }） */
export function cleanJsonText(text: string): string {
  return text.replace(/,\s*([}\]])/g, '$1');
}

/** 容错解析：尾随逗号先清洗再 JSON.parse，仍失败返回 null */
export function parseJsonLenient(text: string): Object | null {
  try {
    return JSON.parse(cleanJsonText(text)) as Object;
  } catch (e) {
    return null;
  }
}
