/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useEffect, useMemo, useRef } from 'react';
import { Play, Pause, SkipBack, SkipForward, RotateCcw, Activity, Database, Clock, AlertTriangle, CheckCircle2, Filter, Download, ChevronDown, ChevronRight } from 'lucide-react';
import { ReactFlow, Background, Controls, Node, Edge } from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { Event, SystemState, TxId, AccountId } from './types';
import { applyEvent, INITIAL_STATE, replay } from './engine';

// --- Simulation Helpers ---
const generateId = () => Math.random().toString(36).substring(2, 9);
const USERS = ['usr_alice', 'usr_bob', 'usr_charlie'];
const MERCHANTS = ['merch_amazon', 'merch_stripe'];

export default function App() {
  const [events, setEvents] = useState<Event[]>([]);
  const [playbackIndex, setPlaybackIndex] = useState<number>(-1); // -1 means tracking latest
  const [isPlaying, setIsPlaying] = useState<boolean>(false);
  const [eventFilter, setEventFilter] = useState<string>('All');
  const [expandedTxId, setExpandedTxId] = useState<string | null>(null);
  
  const eventLogRef = useRef<HTMLDivElement>(null);

  // --- Core Engine Integration ---
  // The current state is purely derived from the event log up to the playback index.
  const effectiveIndex = playbackIndex === -1 ? events.length - 1 : playbackIndex;
  const currentState = useMemo(() => replay(events, effectiveIndex), [events, effectiveIndex]);
  const latestState = useMemo(() => replay(events, events.length - 1), [events]);

  // --- Metrics ---
  const latencyMetrics = useMemo(() => {
    const authLatencies: number[] = [];
    const capLatencies: number[] = [];
    const txTimestamps: Record<string, { init?: number, auth?: number }> = {};

    const visibleEvents = events.slice(0, effectiveIndex + 1);
    for (const ev of visibleEvents) {
      if (!txTimestamps[ev.txId]) txTimestamps[ev.txId] = {};
      if (ev.type === 'EvtInitiated') txTimestamps[ev.txId].init = ev.timestamp;
      if (ev.type === 'EvtAuthorized') {
        txTimestamps[ev.txId].auth = ev.timestamp;
        if (txTimestamps[ev.txId].init) authLatencies.push(ev.timestamp - txTimestamps[ev.txId].init!);
      }
      if (ev.type === 'EvtCaptured') {
        if (txTimestamps[ev.txId].auth) capLatencies.push(ev.timestamp - txTimestamps[ev.txId].auth!);
      }
    }

    const calc = (arr: number[]) => arr.length ? { avg: arr.reduce((a,b)=>a+b,0)/arr.length, max: Math.max(...arr) } : { avg: 0, max: 0 };
    return { auth: calc(authLatencies), cap: calc(capLatencies) };
  }, [events, effectiveIndex]);

  // --- Graph Data ---
  const { nodes, edges } = useMemo(() => {
    const nodes: Node[] = Object.keys(currentState.balances).map((acc, i) => ({
      id: acc,
      position: { x: (i % 3) * 200, y: Math.floor(i / 3) * 150 },
      data: { label: `${acc}\n$${(currentState.balances[acc]/100).toFixed(2)}` },
      style: { background: '#141414', color: '#fff', border: '1px solid #333', borderRadius: '8px', padding: '10px', textAlign: 'center', fontFamily: 'monospace', fontSize: '10px' }
    }));
    
    const edges: Edge[] = Object.values(currentState.transactions).map(tx => ({
      id: tx.id,
      source: tx.from,
      target: tx.to,
      label: `$${(tx.amount/100).toFixed(2)}`,
      animated: tx.state === 'Initiated' || tx.state === 'Authorized',
      style: { stroke: tx.state === 'Failed' ? '#ef4444' : tx.state === 'Captured' ? '#10b981' : '#6366f1' }
    }));
    
    return { nodes, edges };
  }, [currentState]);

  // Auto-scroll event log when tracking latest
  useEffect(() => {
    if (playbackIndex === -1 && eventLogRef.current) {
      eventLogRef.current.scrollTop = eventLogRef.current.scrollHeight;
    }
  }, [events.length, playbackIndex]);

  // --- Simulation Loop ---
  useEffect(() => {
    if (!isPlaying) return;

    const interval = setInterval(() => {
      setTimeout(() => {
        setEvents(prev => {
          const newEvents: Event[] = [];
          const now = Date.now();
        // Use the latest state to determine valid next actions
        const state = replay(prev, prev.length - 1);

        // 1. Randomly initiate new transactions
        if (Math.random() < 0.4) {
          const from = USERS[Math.floor(Math.random() * USERS.length)];
          const to = MERCHANTS[Math.floor(Math.random() * MERCHANTS.length)];
          const amount = Math.floor(Math.random() * 500) + 10;
          newEvents.push({ type: 'EvtInitiated', txId: `tx_${generateId()}`, from, to, amount, timestamp: now });
        }

        // 2. Progress existing transactions (State Machine Transitions)
        Object.values(state.transactions).forEach(tx => {
          // Only process a few at a time to simulate network jitter
          if (Math.random() > 0.3) return; 

          if (tx.state === 'Initiated') {
            // Check balance for authorization
            const balance = state.balances[tx.from] || 0;
            if (balance >= tx.amount) {
              newEvents.push({ type: 'EvtAuthorized', txId: tx.id, timestamp: now });
            } else {
              newEvents.push({ type: 'EvtFailed', txId: tx.id, reason: 'InsufficientFunds', timestamp: now });
            }
          } else if (tx.state === 'Authorized') {
            if (Math.random() < 0.85) {
              newEvents.push({ type: 'EvtCaptured', txId: tx.id, timestamp: now });
            } else if (Math.random() < 0.5) {
              newEvents.push({ type: 'EvtFailed', txId: tx.id, reason: 'NetworkTimeout', timestamp: now });
            }
          }
        });

        if (newEvents.length === 0) return prev;
        return [...prev, ...newEvents];
      });
      }, Math.floor(Math.random() * 500));
    }, 800);

    return () => clearInterval(interval);
  }, [isPlaying]);

  // --- Handlers ---
  const handleScrubberChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setIsPlaying(false);
    const val = parseInt(e.target.value, 10);
    if (val >= events.length - 1) {
      setPlaybackIndex(-1); // Snap to latest
    } else {
      setPlaybackIndex(val);
    }
  };

  const formatMoney = (cents: number) => `$${(cents / 100).toFixed(2)}`;

  const handleExportJSON = () => {
    const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(events, null, 2));
    const downloadAnchorNode = document.createElement('a');
    downloadAnchorNode.setAttribute("href", dataStr);
    downloadAnchorNode.setAttribute("download", "events.json");
    document.body.appendChild(downloadAnchorNode);
    downloadAnchorNode.click();
    downloadAnchorNode.remove();
  };

  return (
    <div className="min-h-screen flex flex-col bg-[#0a0a0a] text-gray-300 font-sans selection:bg-indigo-500/30">
      {/* Header */}
      <header className="border-b border-white/10 bg-[#111] p-4 flex items-center justify-between z-10">
        <div>
          <h1 className="text-xl font-semibold text-white flex items-center gap-2">
            <Activity className="w-5 h-5 text-emerald-500" />
            Deterministic Payment Engine
          </h1>
          <p className="text-xs text-gray-500 mt-1 font-mono">
            Time-Travel Debugging & Event Sourcing Architecture
          </p>
        </div>
        
        {/* Latency Metrics */}
        <div className="hidden md:flex items-center gap-4 text-xs font-mono bg-black/20 px-4 py-2 rounded-lg border border-white/5">
          <div className="flex flex-col">
            <span className="text-gray-500 mb-0.5">Auth Latency</span>
            <span className="text-gray-300">Avg: {latencyMetrics.auth.avg.toFixed(0)}ms | Max: {latencyMetrics.auth.max.toFixed(0)}ms</span>
          </div>
          <div className="w-px h-6 bg-white/10"></div>
          <div className="flex flex-col">
            <span className="text-gray-500 mb-0.5">Capture Latency</span>
            <span className="text-gray-300">Avg: {latencyMetrics.cap.avg.toFixed(0)}ms | Max: {latencyMetrics.cap.max.toFixed(0)}ms</span>
          </div>
        </div>
        
        <div className="flex items-center gap-3">
          <button 
            onClick={() => { setIsPlaying(false); setEvents([]); setPlaybackIndex(-1); }}
            className="p-2 rounded hover:bg-white/5 text-gray-400 hover:text-white transition-colors"
            title="Reset Simulation"
          >
            <RotateCcw className="w-4 h-4" />
          </button>
          <div className="h-6 w-px bg-white/10 mx-1"></div>
          <button 
            onClick={() => {
              setIsPlaying(false);
              setPlaybackIndex(prev => prev === -1 ? Math.max(0, events.length - 2) : Math.max(0, prev - 1));
            }}
            disabled={events.length === 0 || playbackIndex === 0}
            className="p-2 rounded hover:bg-white/5 disabled:opacity-30 transition-colors"
          >
            <SkipBack className="w-4 h-4" />
          </button>
          <button 
            onClick={() => {
              if (playbackIndex !== -1) setIsPlaying(false);
              else setIsPlaying(!isPlaying);
            }}
            className={`flex items-center gap-2 px-4 py-2 rounded-md font-medium transition-all ${
              isPlaying 
                ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20' 
                : 'bg-white/10 text-white hover:bg-white/15'
            }`}
          >
            {isPlaying ? <Pause className="w-4 h-4" /> : <Play className="w-4 h-4" />}
            {isPlaying ? 'Running' : 'Paused'}
          </button>
          <button 
            onClick={() => {
              setIsPlaying(false);
              if (playbackIndex !== -1 && playbackIndex < events.length - 1) {
                setPlaybackIndex(playbackIndex + 1);
              }
            }}
            disabled={events.length === 0 || playbackIndex === -1 || playbackIndex === events.length - 1}
            className="p-2 rounded hover:bg-white/5 disabled:opacity-30 transition-colors"
          >
            <SkipForward className="w-4 h-4" />
          </button>
        </div>
      </header>

      {/* Time Travel Scrubber */}
      <div className="bg-[#141414] border-b border-white/5 p-4 flex items-center gap-4">
        <Clock className="w-4 h-4 text-gray-500 shrink-0" />
        <input 
          type="range" 
          min="0" 
          max={Math.max(0, events.length - 1)} 
          value={effectiveIndex} 
          onChange={handleScrubberChange}
          disabled={events.length === 0}
          className="flex-1 accent-indigo-500 h-1 bg-white/10 rounded-lg appearance-none cursor-pointer"
        />
        <div className="font-mono text-xs text-gray-500 w-24 text-right">
          Event: {events.length > 0 ? effectiveIndex + 1 : 0} / {events.length}
        </div>
      </div>

      {/* Main Content Grid */}
      <main className="flex-1 grid grid-cols-1 lg:grid-cols-12 overflow-hidden">
        
        {/* Left Col: Event Log (The Source of Truth) */}
        <div className="lg:col-span-4 border-r border-white/5 flex flex-col bg-[#0f0f0f]">
          <div className="p-3 border-b border-white/5 bg-[#111] flex flex-col gap-3">
            <div className="flex justify-between items-center">
              <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-400 flex items-center gap-2">
                <Database className="w-3 h-3" />
                Append-Only Event Log
              </h2>
              <span className="text-[10px] font-mono bg-white/10 px-2 py-0.5 rounded text-gray-400">
                Source of Truth
              </span>
            </div>
            <div className="flex items-center gap-1 overflow-x-auto pb-1 [&::-webkit-scrollbar]:hidden">
              <Filter className="w-3 h-3 text-gray-500 mr-1 shrink-0" />
              {['All', 'EvtInitiated', 'EvtAuthorized', 'EvtCaptured', 'EvtFailed'].map(f => (
                <button
                  key={f}
                  onClick={() => setEventFilter(f)}
                  className={`text-[10px] px-2 py-1 rounded whitespace-nowrap transition-colors ${
                    eventFilter === f ? 'bg-indigo-500/20 text-indigo-300 border border-indigo-500/30' : 'bg-white/5 text-gray-400 hover:bg-white/10 border border-transparent'
                  }`}
                >
                  {f.replace('Evt', '')}
                </button>
              ))}
              <div className="flex-1"></div>
              <button onClick={handleExportJSON} className="text-[10px] px-2 py-1 rounded bg-white/5 text-gray-400 hover:bg-white/10 border border-transparent flex items-center gap-1 transition-colors">
                <Download className="w-3 h-3" /> Export
              </button>
            </div>
          </div>
          <div className="flex-1 overflow-y-auto p-2 space-y-1" ref={eventLogRef}>
            {events.length === 0 ? (
              <div className="h-full flex items-center justify-center text-sm text-gray-600 italic">
                No events yet. Press Play.
              </div>
            ) : (
              events
                .map((evt, idx) => ({ evt, idx }))
                .filter(({ evt }) => eventFilter === 'All' || evt.type === eventFilter)
                .map(({ evt, idx }) => {
                const isPast = idx <= effectiveIndex;
                const isCurrent = idx === effectiveIndex;
                
                let colorClass = 'text-gray-400';
                if (evt.type === 'EvtInitiated') colorClass = 'text-blue-400';
                if (evt.type === 'EvtAuthorized') colorClass = 'text-yellow-400';
                if (evt.type === 'EvtCaptured') colorClass = 'text-emerald-400';
                if (evt.type === 'EvtFailed') colorClass = 'text-red-400';

                return (
                  <div 
                    key={idx}
                    onClick={() => { setIsPlaying(false); setPlaybackIndex(idx); }}
                    className={`p-2 rounded text-xs font-mono cursor-pointer transition-all border border-transparent
                      ${isCurrent ? 'bg-indigo-500/20 border-indigo-500/30 text-white' : ''}
                      ${!isPast ? 'opacity-30 grayscale' : 'hover:bg-white/5'}
                    `}
                  >
                    <div className="flex justify-between items-start mb-1">
                      <span className={`font-semibold ${colorClass}`}>{evt.type}</span>
                      <span className="text-[10px] text-gray-600">#{idx}</span>
                    </div>
                    <div className="text-gray-400">
                      tx: <span className="text-gray-300">{evt.txId}</span>
                    </div>
                    {evt.type === 'EvtInitiated' && (
                      <div className="text-gray-500 mt-1">
                        {evt.from} &rarr; {evt.to} ({formatMoney(evt.amount)})
                      </div>
                    )}
                    {evt.type === 'EvtFailed' && (
                      <div className="text-red-400/70 mt-1 flex items-center gap-1">
                        <AlertTriangle className="w-3 h-3" /> {evt.reason}
                      </div>
                    )}
                  </div>
                );
              })
            )}
          </div>
        </div>

        {/* Right Col: Materialized Views */}
        <div className="lg:col-span-8 flex flex-col bg-[#0a0a0a]">
          
          {/* Top Half: Account Balances */}
          <div className="h-1/4 border-b border-white/5 flex flex-col">
            <div className="p-3 border-b border-white/5 bg-[#111]">
              <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-400">
                Materialized View: Balances
              </h2>
            </div>
            <div className="flex-1 overflow-y-auto p-4">
              <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                {Object.entries(currentState.balances).map(([acc, bal]) => (
                  <div key={acc} className="bg-[#141414] border border-white/5 rounded-lg p-4 flex flex-col">
                    <span className="text-xs text-gray-500 font-mono mb-1">{acc}</span>
                    <span className={`text-xl font-mono ${bal < 0 ? 'text-red-400' : 'text-white'}`}>
                      {formatMoney(bal)}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </div>

          {/* Middle: Active Transactions */}
          <div className="h-2/5 border-b border-white/5 flex flex-col min-h-0">
            <div className="p-3 border-b border-white/5 bg-[#111] flex flex-col gap-3">
              <div className="flex justify-between items-center">
                <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-400">
                  Materialized View: State Machines
                </h2>
                <div className="text-[10px] text-gray-500 font-mono">
                  Showing state at event #{effectiveIndex >= 0 ? effectiveIndex : '-'}
                </div>
              </div>
              
              {/* Metrics Section */}
              <div className="flex items-center gap-4 text-xs">
                <div className="bg-white/5 px-3 py-1.5 rounded flex items-center gap-2">
                  <span className="text-gray-500">Total:</span>
                  <span className="font-mono text-gray-300">{Object.keys(currentState.transactions).length}</span>
                </div>
                <div className="bg-emerald-500/5 border border-emerald-500/10 px-3 py-1.5 rounded flex items-center gap-2">
                  <span className="text-emerald-500/70">Success:</span>
                  <span className="font-mono text-emerald-400">
                    {Object.values(currentState.transactions).filter(tx => tx.state === 'Captured' || tx.state === 'Settled').length}
                  </span>
                </div>
                <div className="bg-red-500/5 border border-red-500/10 px-3 py-1.5 rounded flex items-center gap-2">
                  <span className="text-red-500/70">Failed:</span>
                  <span className="font-mono text-red-400">
                    {Object.values(currentState.transactions).filter(tx => tx.state === 'Failed').length}
                  </span>
                </div>
              </div>
            </div>
            <div className="flex-1 overflow-y-auto p-4">
              <div className="space-y-2">
                {Object.values(currentState.transactions).reverse().map(tx => {
                  let statusColor = 'bg-gray-500/10 text-gray-400 border-gray-500/20';
                  if (tx.state === 'Initiated') statusColor = 'bg-blue-500/10 text-blue-400 border-blue-500/20';
                  if (tx.state === 'Authorized') statusColor = 'bg-yellow-500/10 text-yellow-400 border-yellow-500/20';
                  if (tx.state === 'Captured') statusColor = 'bg-emerald-500/10 text-emerald-400 border-emerald-500/20';
                  if (tx.state === 'Failed') statusColor = 'bg-red-500/10 text-red-400 border-red-500/20';

                  return (
                    <div key={tx.id} className="bg-[#141414] border border-white/5 rounded-lg p-3 flex flex-col cursor-pointer hover:bg-white/5 transition-colors" onClick={() => setExpandedTxId(expandedTxId === tx.id ? null : tx.id)}>
                      <div className="flex items-center justify-between">
                        <div className="flex items-center gap-4">
                          <div className={`px-2 py-1 rounded border text-[10px] font-mono uppercase tracking-wider w-24 text-center ${statusColor}`}>
                            {tx.state}
                          </div>
                          <div>
                            <div className="font-mono text-sm text-gray-200 flex items-center gap-2">
                              {expandedTxId === tx.id ? <ChevronDown className="w-3 h-3" /> : <ChevronRight className="w-3 h-3" />}
                              {tx.id}
                            </div>
                            <div className="text-xs text-gray-500 mt-0.5">
                              {tx.from} &rarr; {tx.to}
                            </div>
                          </div>
                        </div>
                        <div className="text-right">
                          <div className="font-mono text-sm text-white">{formatMoney(tx.amount)}</div>
                          {tx.failureReason && (
                            <div className="text-[10px] text-red-400 mt-1 flex items-center justify-end gap-1">
                              <AlertTriangle className="w-3 h-3" /> {tx.failureReason}
                            </div>
                          )}
                          {tx.state === 'Captured' && (
                            <div className="text-[10px] text-emerald-400 mt-1 flex items-center justify-end gap-1">
                              <CheckCircle2 className="w-3 h-3" /> Settled
                            </div>
                          )}
                        </div>
                      </div>
                      
                      {/* Expanded Details */}
                      {expandedTxId === tx.id && (
                        <div className="mt-3 pt-3 border-t border-white/5 text-xs text-gray-400 font-mono space-y-1">
                          {tx.initiatedAt && <div><span className="text-gray-500 w-24 inline-block">Initiated:</span> {new Date(tx.initiatedAt).toISOString()}</div>}
                          {tx.authorizedAt && <div><span className="text-gray-500 w-24 inline-block">Authorized:</span> {new Date(tx.authorizedAt).toISOString()}</div>}
                          {tx.capturedAt && <div><span className="text-gray-500 w-24 inline-block">Captured:</span> {new Date(tx.capturedAt).toISOString()}</div>}
                          {tx.failedAt && <div><span className="text-gray-500 w-24 inline-block">Failed:</span> {new Date(tx.failedAt).toISOString()}</div>}
                          {tx.failureReason && <div className="text-red-400 mt-2">Reason: {tx.failureReason}</div>}
                        </div>
                      )}
                    </div>
                  );
                })}
                {Object.keys(currentState.transactions).length === 0 && (
                  <div className="text-center text-sm text-gray-600 italic py-8">
                    No transactions in the current state.
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* Bottom: Transaction Graph */}
          <div className="flex-1 flex flex-col min-h-0">
            <div className="p-3 border-b border-white/5 bg-[#111]">
              <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-400">
                Transaction Graph
              </h2>
            </div>
            <div className="flex-1 bg-[#0a0a0a]">
              <ReactFlow nodes={nodes} edges={edges} fitView>
                <Background color="#333" gap={16} />
                <Controls />
              </ReactFlow>
            </div>
          </div>

        </div>
      </main>
    </div>
  );
}
