import { execFileSync } from 'node:child_process';
import path from 'node:path';

// Fresh test database with migrations and the development seed for every run.
export default function setup() {
  const root = path.resolve(__dirname, '../../..');
  execFileSync(path.join(root, 'scripts/db-reset.sh'), [process.env.TEST_DB_NAME ?? 'rms_test', '--seed'], { stdio: 'inherit' });
}
