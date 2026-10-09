import { loadRules, resolve } from './rules';
import { rulesFile, stateHome } from './paths';
const path = process.argv[2] ?? await rulesFile(process.cwd(), stateHome());
console.error(`Checking ${path}`);
try { const rules = await loadRules(path); console.log(JSON.stringify(resolve(rules, { app: process.argv[3] ?? 'Google Chrome', title: process.argv[4] ?? 'general - Workspace - Slack', mode: 'read' }), null, 2)); }
catch (e) { console.error(String(e)); process.exit(1); }
