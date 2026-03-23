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
// This function takes the current state and an event, and returns a NEW state.
// It enforces the state machine rules (e.g., cannot capture an un-authorized tx).
export function applyEvent(state: SystemState, event: Event): SystemState {
  // Structural sharing / deep copy for immutability
  const nextState: SystemState = {
    balances: { ...state.balances },
    transactions: { ...state.transactions }
  };

  switch (event.type) {
    case 'EvtInitiated':
      nextState.transactions[event.txId] = {
        id: event.txId,
        from: event.from,
        to: event.to,
        amount: event.amount,
        state: 'Initiated',
        createdAt: event.timestamp,
        updatedAt: event.timestamp
      };
      break;

    case 'EvtAuthorized': {
      const tx = nextState.transactions[event.txId];
      if (tx && tx.state === 'Initiated') {
        nextState.transactions[event.txId] = {
          ...tx,
          state: 'Authorized',
          updatedAt: event.timestamp
        };
      }
      break;
    }

    case 'EvtCaptured': {
      const tx = nextState.transactions[event.txId];
      if (tx && tx.state === 'Authorized') {
        // Move the money
        nextState.balances[tx.from] -= tx.amount;
        nextState.balances[tx.to] += tx.amount;
        
        nextState.transactions[event.txId] = {
          ...tx,
          state: 'Captured',
          updatedAt: event.timestamp
        };
      }
      break;
    }

    case 'EvtFailed': {
      const tx = nextState.transactions[event.txId];
      if (tx && tx.state !== 'Captured' && tx.state !== 'Settled') {
        nextState.transactions[event.txId] = {
          ...tx,
          state: 'Failed',
          failureReason: event.reason,
          updatedAt: event.timestamp
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
