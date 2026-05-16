// Onyxia parses PALETTE_OVERRIDE_* and FONT as JSON5 (per web/src/env.ts).
// We emit valid JSON5 — unquoted single-token keys, single-quoted strings —
// because that's what Onyxia's existing examples (InseeFrLab, sspcloud)
// use and it stays readable in helm values dumps.
const SAFE_KEY = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

export function json5Stringify(value, indent = 2) {
  return _emit(value, '', indent);
}

function _emit(v, prefix, indent) {
  if (v === null) return 'null';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (typeof v === 'string') return `'${v.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
  if (Array.isArray(v)) {
    if (v.length === 0) return '[]';
    const inner = prefix + ' '.repeat(indent);
    return '[\n' + v.map(x => inner + _emit(x, inner, indent)).join(',\n') + '\n' + prefix + ']';
  }
  if (typeof v === 'object') {
    const keys = Object.keys(v);
    if (keys.length === 0) return '{}';
    const inner = prefix + ' '.repeat(indent);
    return '{\n' + keys.map(k => {
      const key = SAFE_KEY.test(k) ? k : `'${k}'`;
      return inner + `${key}: ${_emit(v[k], inner, indent)}`;
    }).join(',\n') + '\n' + prefix + '}';
  }
  throw new Error('json5Stringify: unsupported value ' + typeof v);
}
