// Execute the unchanged cwd checks from the pinned upstream source, not its schema.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const source = fs.readFileSync(path.join(__dirname, 'agent-request-preflight.ts'), 'utf8');
if (crypto.createHash('sha256').update(source).digest('hex') !== '64d6f0a61befd62a40921d602129b113524c7308285c34db588654e80ff38c28') throw Error('Fixture changed');
const checks = source.slice(source.indexOf('  if (request.cwd'), source.indexOf('  const allowModelOverride ='));
const probe = new Function('request', 'params', 'path', 'normalizeOptionalString', 'errorShape', 'ErrorCodes', checks);
let reply = {allowed: true};
probe(JSON.parse(process.argv[2]), {client: {connect: {client: {id: 'cli', mode: 'cli'}}}, io: {emitAcceptance: value => {reply = {allowed: false, error: value[2]};}}}, path, value => value?.trim(), (code, message) => ({code, message}), {INVALID_REQUEST: 'INVALID_REQUEST'});
process.stdout.write(JSON.stringify(reply));
