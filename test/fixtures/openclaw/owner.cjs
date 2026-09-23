// Execute the unchanged upstream authorization functions, with only their
// whitespace normalizer and scope constant supplied at the boundary.
const fs = require('node:fs');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const source = fs.readFileSync(__dirname + '/chat-abort-authorization.ts', 'utf8');
const context = { ADMIN_SCOPE: 'operator.admin', normalizeOptionalText: v => typeof v === 'string' ? v.trim() || undefined : undefined };
vm.createContext(context);
vm.runInContext(stripTypeScriptTypes(source.replaceAll('export function', 'function')), context);
module.exports = context;
