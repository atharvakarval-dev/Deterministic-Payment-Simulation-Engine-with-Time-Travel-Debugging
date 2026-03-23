export type AccountId = string;
export type TxId = string;
export type Money = number;

export type TxState = 'Initiated' | 'Authorized' | 'Captured' | 'Settled' | 'Failed';
export type FailureReason = 'InsufficientFunds' | 'NetworkTimeout' | 'FraudDetected' | 'Timeout';

// 1. Domain Modeling: Events as Discriminated Unions (ADTs)
export type Event =
  | { type: 'EvtInitiated'; txId: TxId; from: AccountId; to: AccountId; amount: Money; timestamp: number }
  | { type: 'EvtAuthorized'; txId: TxId; timestamp: number }
  | { type: 'EvtCaptured'; txId: TxId; timestamp: number }
  | { type: 'EvtFailed'; txId: TxId; reason: FailureReason; timestamp: number };

export interface TransactionDetails {
  id: TxId;
  from: AccountId;
  to: AccountId;
  amount: Money;
  state: TxState;
  failureReason?: FailureReason;
  createdAt: number;
  updatedAt: number;
  initiatedAt?: number;
  authorizedAt?: number;
  capturedAt?: number;
  failedAt?: number;
  retryCount?: number;
}

// 2. System State: The materialized view of the event log
export interface SystemState {
  balances: Record<AccountId, Money>;
  transactions: Record<TxId, TransactionDetails>;
}
