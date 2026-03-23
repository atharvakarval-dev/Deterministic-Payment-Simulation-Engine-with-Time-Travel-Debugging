// useHaskellEngine.ts
//
// Connects the React frontend to the Haskell payment-engine binary via the
// Express bridge server (server.ts).
//
// Protocol: POST /api/simulate or /api/scenario starts a run.
// The server responds with an SSE stream where each line is a JSON Event
// matching the frontend Event type exactly.
//
// The hook is a drop-in replacement for the local simulation loop:
// it returns { events, isConnected, error, run, runScenario, reset }
// and App.tsx switches between local and haskell sources with a toggle.

import { useState, useRef, useCallback } from 'react';
import { Event, SimulateParams, ScenarioName } from './types';

interface HaskellEngineState {
  events: Event[];
  isConnected: boolean;
  error: string | null;
}

interface HaskellEngineActions {
  run: (params: SimulateParams) => void;
  runScenario: (name: ScenarioName) => void;
  reset: () => void;
}

export function useHaskellEngine(): HaskellEngineState & HaskellEngineActions {
  const [events, setEvents] = useState<Event[]>([]);
  const [isConnected, setIsConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const esRef = useRef<EventSource | null>(null);

  const closeStream = useCallback(() => {
    esRef.current?.close();
    esRef.current = null;
    setIsConnected(false);
  }, []);

  const openStream = useCallback((url: string) => {
    closeStream();
    setEvents([]);
    setError(null);

    const es = new EventSource(url);
    esRef.current = es;
    setIsConnected(true);

    es.onmessage = (e) => {
      try {
        const event: Event = JSON.parse(e.data);
        setEvents(prev => [...prev, event]);
      } catch {
        // non-event SSE message (e.g. heartbeat), ignore
      }
    };

    es.addEventListener('done', () => closeStream());

    es.onerror = () => {
      setError('Lost connection to Haskell engine. Is the server running?');
      closeStream();
    };
  }, [closeStream]);

  const run = useCallback((params: SimulateParams) => {
    const qs = new URLSearchParams({
      users:   String(params.users),
      txns:    String(params.txns),
      workers: String(params.workers),
      seed:    String(params.seed),
      fraud:   String(params.fraud),
      timeout: String(params.timeout),
    });
    openStream(`/api/simulate?${qs}`);
  }, [openStream]);

  const runScenario = useCallback((name: ScenarioName) => {
    openStream(`/api/scenario?name=${name}`);
  }, [openStream]);

  const reset = useCallback(() => {
    closeStream();
    setEvents([]);
    setError(null);
  }, [closeStream]);

  return { events, isConnected, error, run, runScenario, reset };
}
