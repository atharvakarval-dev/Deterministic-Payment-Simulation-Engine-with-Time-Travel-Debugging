import { SystemState, Event } from './types';

export const INITIAL_STATE: SystemState = {
  balances: {
    'usr_alice': 15000,
    'usr_bob': 8500,
    'usr_charlie': 3200,
    'merch_amazon': 0,
    'merch_stripe': 0,
  },
  transactions: {}
};

// 3. Functional Core: 100% Pure Reducer
export function applyFraudRules(state: SystemState, event: Event): Event | null {
  if (event.type === 'EvtInitiated') {
    // Rule 1: Unusually large amounts
    if (event.amount > 400) {
      return { type: 'EvtFailed', txId: event.txId, reason: 'FraudDetected', timestamp: event.timestamp + 1 };
    }
    // Rule 2: Multiple failed transactions for the same user
    const userFailedTxs = Object.values(state.transactions).filter(tx => tx.from === event.from && tx.state === 'Failed');
    if (userFailedTxs.length >= 2) {
      return { type: 'EvtFailed', txId: event.txId, reason: 'FraudDetected', timestamp: event.timestamp + 1 };
    }
  }
  return null;
}

export function applyTimeouts(state: SystemState, currentTimestamp: number): SystemState {
  let hasChanges = false;
  const nextTxs = { ...state.transactions };
  for (const [id, tx] of Object.entries(nextTxs)) {
    if (tx.state === 'Initiated' && tx.initiatedAt && (currentTimestamp - tx.initiatedAt > 60000)) {
      nextTxs[id] = {
        ...tx,
        state: 'Failed',
        failureReason: 'Timeout',
        updatedAt: currentTimestamp,
        failedAt: currentTimestamp
      };
      hasChanges = true;
    }
  }
  return hasChanges ? { ...state, transactions: nextTxs } : state;
}

export function applyEvent(state: SystemState, event: Event): SystemState {
  let nextState = applyTimeouts(state, event.timestamp);
  const fraudEvent = applyFraudRules(nextState, event);
  nextState = applyRawEvent(nextState, event);
  if (fraudEvent) {
    nextState = applyRawEvent(nextState, fraudEvent);
  }
  return nextState;
}

function applyRawEvent(state: SystemState, event: Event): SystemState {
  // Structural sharing / deep copy for immutability
  const nextState: SystemState = {
    balances: { ...state.balances },
    transactions: { ...state.transactions }
  };

  switch (event.type) {
    case 'EvtInitiated': {
      const existingTx = nextState.transactions[event.txId];
      if (existingTx) {
        if (existingTx.state === 'Failed' && existingTx.failureReason === 'NetworkTimeout' && (existingTx.retryCount || 0) < 1) {
          nextState.transactions[event.txId] = {
            ...existingTx,
            state: 'Initiated',
            amount: event.amount,
            updatedAt: event.timestamp,
            initiatedAt: event.timestamp,
            retryCount: (existingTx.retryCount || 0) + 1,
            failureReason: undefined,
            failedAt: undefined
          };
        }
        break; // Idempotent if not a valid retry
      }
      nextState.transactions[event.txId] = {
        id: event.txId,
        from: event.from,
        to: event.to,
        amount: event.amount,
        state: 'Initiated',
        createdAt: event.timestamp,
        updatedAt: event.timestamp,
        initiatedAt: event.timestamp,
        retryCount: 0
      };
      break;
    }

    case 'EvtAuthorized': {
      const tx = nextState.transactions[event.txId];
      if (tx && tx.state === 'Authorized') return state; // Idempotent
      if (tx && tx.state === 'Initiated') {
        nextState.transactions[event.txId] = {
          ...tx,
          state: 'Authorized',
          updatedAt: event.timestamp,
          authorizedAt: event.timestamp
        };
      }
      break;
    }

    case 'EvtCaptured': {
      const tx = nextState.transactions[event.txId];
      if (tx && tx.state === 'Captured') return state; // Idempotent
      if (tx && tx.state === 'Authorized') {
        // Move the money
        nextState.balances[tx.from] -= tx.amount;
        nextState.balances[tx.to] += tx.amount;
        
        nextState.transactions[event.txId] = {
          ...tx,
          state: 'Captured',
          updatedAt: event.timestamp,
          capturedAt: event.timestamp
        };
      }
      break;
    }

    case 'EvtFailed': {
      const tx = nextState.transactions[event.txId];
      if (tx && tx.state === 'Failed') return state; // Idempotent
      if (tx && tx.state !== 'Captured' && tx.state !== 'Settled') {
        nextState.transactions[event.txId] = {
          ...tx,
          state: 'Failed',
          failureReason: event.reason,
          updatedAt: event.timestamp,
          failedAt: event.timestamp
        };
      }
      break;
    }
  }

  return nextState;
}

// 4. Time-Travel Debugging: Replay the system up to any point
export function replay(events: Event[], upToIndex: number): SystemState {
  if (upToIndex < 0) return INITIAL_STATE;
  const eventsToApply = events.slice(0, upToIndex + 1);
  return eventsToApply.reduce(applyEvent, INITIAL_STATE);
}
