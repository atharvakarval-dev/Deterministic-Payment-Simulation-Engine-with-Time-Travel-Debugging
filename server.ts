// server.ts — Express bridge: React frontend ↔ Haskell payment-engine binary
//
// Protocol: each GET endpoint spawns the Haskell binary and streams its
// stdout (one JSON Event per line) back to the browser as SSE.
//
// Build Haskell first:  cd payment-engine && stack build
// Then run both:        npm run dev:all

import express from 'express';
import { spawn } from 'child_process';
import path from 'path';

const app  = express();
const PORT = 3001;

const useStack   = !process.env.PAYMENT_ENGINE_BIN;
const HASKELL_BIN = process.env.PAYMENT_ENGINE_BIN ?? 'payment-engine';
const HASKELL_DIR = path.resolve(__dirname, 'payment-engine');

// ── SSE helpers ───────────────────────────────────────────────────────────

function sseOpen(res: express.Response) {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.flushHeaders();
}

const sseData = (res: express.Response, d: string) => res.write(`data: ${d}\n\n`);
const sseDone = (res: express.Response) => { res.write('event: done\ndata: {}\n\n'); res.end(); };

// ── Spawn Haskell → SSE ───────────────────────────────────────────────────

function streamHaskell(res: express.Response, args: string[]) {
  sseOpen(res);

  const cmd  = useStack ? 'stack' : HASKELL_BIN;
  const argv = useStack ? ['exec', 'payment-engine', '--', ...args] : args;

  const child = spawn(cmd, argv, { cwd: HASKELL_DIR, stdio: ['ignore', 'pipe', 'pipe'] });

  let buf = '';
  child.stdout.on('data', (chunk: Buffer) => {
    buf += chunk.toString();
    const lines = buf.split('\n');
    buf = lines.pop() ?? '';
    for (const line of lines) {
      const t = line.trim();
      if (t.startsWith('{')) sseData(res, t);
    }
  });

  // Forward Haskell stderr as SSE comments (visible in browser DevTools)
  child.stderr.on('data', (chunk: Buffer) => {
    const t = chunk.toString().trim();
    if (t) res.write(`: ${t}\n\n`);
  });

  child.on('close', () => sseDone(res));
  child.on('error', (err) => { sseData(res, JSON.stringify({ error: err.message })); sseDone(res); });
  res.on('close', () => child.kill());
}

// ── Routes ────────────────────────────────────────────────────────────────

app.get('/api/simulate', (req, res) => {
  const q = req.query as Record<string, string>;
  streamHaskell(res, [
    'simulate', '--json',
    '--users',   q.users   ?? '100',
    '--txns',    q.txns    ?? '500',
    '--workers', q.workers ?? '4',
    '--seed',    q.seed    ?? '42',
    '--fraud',   q.fraud   ?? '0.05',
    '--timeout', q.timeout ?? '0.03',
  ]);
});

app.get('/api/scenario', (req, res) => {
  streamHaskell(res, ['scenario', '--json', '--name', (req.query.name as string) ?? 'race']);
});

app.get('/api/replay', (req, res) => {
  const q = req.query as Record<string, string>;
  streamHaskell(res, ['replay', '--json', '--until', q.until ?? '100', '--txns', q.txns ?? '500', '--seed', q.seed ?? '42']);
});

app.get('/api/health', (_req, res) => {
  res.json({ status: 'ok', engine: useStack ? 'stack exec payment-engine' : HASKELL_BIN });
});

app.listen(PORT, () => {
  console.log(`[bridge] http://localhost:${PORT}`);
  console.log(`[bridge] engine: ${useStack ? 'stack exec payment-engine' : HASKELL_BIN}`);
});
