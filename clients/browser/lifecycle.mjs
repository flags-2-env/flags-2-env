const freeze = Object.freeze;

export const MainThreadPhase = freeze({
  INITIALIZING: "initializing",
  READY: "ready",
  CALLING: "calling",
  FAILED: "failed",
});

export const MainThreadEvent = freeze({
  INITIALIZED: "initialized",
  INITIALIZATION_FAILED: "initialization_failed",
  CALL_STARTED: "call_started",
  CALL_SETTLED: "call_settled",
  FAULT: "fault",
});

export const WorkerClientPhase = freeze({
  STARTING: "starting",
  READY: "ready",
  DRAINING: "draining",
  CLOSED: "closed",
  FAILED: "failed",
});

export const WorkerClientEvent = freeze({
  INITIALIZE_REQUESTED: "initialize_requested",
  INITIALIZED: "initialized",
  INITIALIZATION_FAILED: "initialization_failed",
  REQUEST_STARTED: "request_started",
  REQUEST_SETTLED: "request_settled",
  CLOSE_REQUESTED: "close_requested",
  DRAIN_COMPLETED: "drain_completed",
  TERMINATE: "terminate",
  FAULT: "fault",
});

export const WorkerHostPhase = freeze({
  UNINITIALIZED: "uninitialized",
  INITIALIZING: "initializing",
  READY: "ready",
  FAILED: "failed",
});

export const WorkerHostEvent = freeze({
  INITIALIZE_REQUESTED: "initialize_requested",
  INITIALIZED: "initialized",
  INITIALIZATION_FAILED: "initialization_failed",
  CALL_REQUESTED: "call_requested",
  FAULT: "fault",
});

export const DemoPhase = freeze({
  INITIALIZING: "initializing",
  READY: "ready",
  FAILED: "failed",
});

export const DemoEvent = freeze({
  INITIALIZED: "initialized",
  INITIALIZATION_FAILED: "initialization_failed",
});

const MAIN_THREAD_PHASES = new Set(Object.values(MainThreadPhase));
const MAIN_THREAD_EVENTS = new Set(Object.values(MainThreadEvent));
const WORKER_CLIENT_PHASES = new Set(Object.values(WorkerClientPhase));
const WORKER_CLIENT_EVENTS = new Set(Object.values(WorkerClientEvent));
const WORKER_HOST_PHASES = new Set(Object.values(WorkerHostPhase));
const WORKER_HOST_EVENTS = new Set(Object.values(WorkerHostEvent));
const DEMO_PHASES = new Set(Object.values(DemoPhase));
const DEMO_EVENTS = new Set(Object.values(DemoEvent));

function result(state, accepted, code = "ok") {
  return freeze({ state: freeze(state), accepted, code });
}

function phaseResult(phase, accepted, code = "ok") {
  return result({ phase }, accepted, code);
}

function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function initialMainThreadState() {
  return freeze({ phase: MainThreadPhase.INITIALIZING });
}

export function isValidMainThreadState(state) {
  return isRecord(state) && MAIN_THREAD_PHASES.has(state.phase);
}

export function reduceMainThreadLifecycle(state, event) {
  if (!isValidMainThreadState(state) || !MAIN_THREAD_EVENTS.has(event)) {
    return phaseResult(MainThreadPhase.FAILED, false, "invalid_transition_input");
  }

  const { phase } = state;
  if (phase === MainThreadPhase.FAILED) {
    return phaseResult(phase, event === MainThreadEvent.FAULT, "terminal");
  }
  if (event === MainThreadEvent.FAULT) {
    return phaseResult(MainThreadPhase.FAILED, true);
  }
  if (event === MainThreadEvent.INITIALIZED) {
    return phase === MainThreadPhase.INITIALIZING
      ? phaseResult(MainThreadPhase.READY, true)
      : phaseResult(MainThreadPhase.FAILED, false, "invalid_internal_event");
  }
  if (event === MainThreadEvent.INITIALIZATION_FAILED) {
    return phase === MainThreadPhase.INITIALIZING
      ? phaseResult(MainThreadPhase.FAILED, true)
      : phaseResult(MainThreadPhase.FAILED, false, "invalid_internal_event");
  }
  if (event === MainThreadEvent.CALL_STARTED) {
    if (phase === MainThreadPhase.READY) {
      return phaseResult(MainThreadPhase.CALLING, true);
    }
    if (phase === MainThreadPhase.CALLING) {
      return phaseResult(phase, false, "busy");
    }
    return phaseResult(MainThreadPhase.FAILED, false, "not_ready");
  }
  if (event === MainThreadEvent.CALL_SETTLED) {
    return phase === MainThreadPhase.CALLING
      ? phaseResult(MainThreadPhase.READY, true)
      : phaseResult(MainThreadPhase.FAILED, false, "invalid_internal_event");
  }
  return phaseResult(MainThreadPhase.FAILED, false, "unhandled_known_event");
}

export function initialWorkerClientState() {
  return freeze({ phase: WorkerClientPhase.STARTING, pending: 0 });
}

export function isWorkerClientTerminal(state) {
  return (
    isRecord(state) &&
    (state.phase === WorkerClientPhase.CLOSED || state.phase === WorkerClientPhase.FAILED)
  );
}

export function isValidWorkerClientState(state, limit) {
  if (
    !isRecord(state) ||
    !WORKER_CLIENT_PHASES.has(state.phase) ||
    !Number.isInteger(limit) ||
    limit < 1 ||
    !Number.isInteger(state.pending) ||
    state.pending < 0 ||
    state.pending > limit
  ) {
    return false;
  }
  if (isWorkerClientTerminal(state) && state.pending !== 0) return false;
  if (state.phase === WorkerClientPhase.STARTING && state.pending > 1) return false;
  return true;
}

function clientResult(phase, pending, accepted, code = "ok") {
  return result({ phase, pending }, accepted, code);
}

export function reduceWorkerClientLifecycle(state, event, limit) {
  if (!isValidWorkerClientState(state, limit) || !WORKER_CLIENT_EVENTS.has(event)) {
    return clientResult(WorkerClientPhase.FAILED, 0, false, "invalid_transition_input");
  }

  const { phase, pending } = state;
  if (isWorkerClientTerminal(state)) {
    const accepted =
      (phase === WorkerClientPhase.CLOSED && event === WorkerClientEvent.TERMINATE) ||
      (phase === WorkerClientPhase.FAILED && event === WorkerClientEvent.FAULT);
    return clientResult(phase, 0, accepted, "terminal");
  }
  if (event === WorkerClientEvent.TERMINATE) {
    return clientResult(WorkerClientPhase.CLOSED, 0, true);
  }
  if (event === WorkerClientEvent.FAULT) {
    return clientResult(WorkerClientPhase.FAILED, 0, true);
  }
  if (event === WorkerClientEvent.INITIALIZE_REQUESTED) {
    return phase === WorkerClientPhase.STARTING && pending === 0
      ? clientResult(phase, 1, true)
      : clientResult(phase, pending, false, "initialization_already_started");
  }
  if (event === WorkerClientEvent.INITIALIZED) {
    return phase === WorkerClientPhase.STARTING && pending === 1
      ? clientResult(WorkerClientPhase.READY, 0, true)
      : clientResult(WorkerClientPhase.FAILED, 0, false, "invalid_internal_event");
  }
  if (event === WorkerClientEvent.INITIALIZATION_FAILED) {
    return phase === WorkerClientPhase.STARTING && pending === 1
      ? clientResult(WorkerClientPhase.FAILED, 0, true)
      : clientResult(WorkerClientPhase.FAILED, 0, false, "invalid_internal_event");
  }
  if (event === WorkerClientEvent.REQUEST_STARTED) {
    if (phase === WorkerClientPhase.READY && pending < limit) {
      return clientResult(phase, pending + 1, true);
    }
    if (phase === WorkerClientPhase.READY) {
      return clientResult(phase, pending, false, "busy");
    }
    if (phase === WorkerClientPhase.DRAINING) {
      return clientResult(phase, pending, false, "closing");
    }
    return clientResult(phase, pending, false, "not_ready");
  }
  if (event === WorkerClientEvent.REQUEST_SETTLED) {
    if (
      (phase === WorkerClientPhase.READY || phase === WorkerClientPhase.DRAINING) &&
      pending > 0
    ) {
      return clientResult(phase, pending - 1, true);
    }
    return clientResult(WorkerClientPhase.FAILED, 0, false, "invalid_internal_event");
  }
  if (event === WorkerClientEvent.CLOSE_REQUESTED) {
    if (phase === WorkerClientPhase.READY) {
      return clientResult(WorkerClientPhase.DRAINING, pending, true);
    }
    if (phase === WorkerClientPhase.DRAINING) {
      return clientResult(phase, pending, true, "already_closing");
    }
    return clientResult(phase, pending, false, "not_ready");
  }
  if (event === WorkerClientEvent.DRAIN_COMPLETED) {
    return phase === WorkerClientPhase.DRAINING && pending === 0
      ? clientResult(WorkerClientPhase.CLOSED, 0, true)
      : clientResult(WorkerClientPhase.FAILED, 0, false, "invalid_internal_event");
  }
  return clientResult(WorkerClientPhase.FAILED, 0, false, "unhandled_known_event");
}

export function initialWorkerHostState() {
  return freeze({ phase: WorkerHostPhase.UNINITIALIZED });
}

export function isValidWorkerHostState(state) {
  return isRecord(state) && WORKER_HOST_PHASES.has(state.phase);
}

export function reduceWorkerHostLifecycle(state, event) {
  if (!isValidWorkerHostState(state) || !WORKER_HOST_EVENTS.has(event)) {
    return phaseResult(WorkerHostPhase.FAILED, false, "invalid_transition_input");
  }

  const { phase } = state;
  if (phase === WorkerHostPhase.FAILED) {
    return phaseResult(phase, event === WorkerHostEvent.FAULT, "terminal");
  }
  if (event === WorkerHostEvent.FAULT) {
    return phaseResult(WorkerHostPhase.FAILED, true);
  }
  if (event === WorkerHostEvent.INITIALIZE_REQUESTED) {
    return phase === WorkerHostPhase.UNINITIALIZED
      ? phaseResult(WorkerHostPhase.INITIALIZING, true)
      : phaseResult(phase, false, "already_initialized");
  }
  if (event === WorkerHostEvent.INITIALIZED) {
    return phase === WorkerHostPhase.INITIALIZING
      ? phaseResult(WorkerHostPhase.READY, true)
      : phaseResult(WorkerHostPhase.FAILED, false, "invalid_internal_event");
  }
  if (event === WorkerHostEvent.INITIALIZATION_FAILED) {
    return phase === WorkerHostPhase.INITIALIZING
      ? phaseResult(WorkerHostPhase.FAILED, true)
      : phaseResult(WorkerHostPhase.FAILED, false, "invalid_internal_event");
  }
  if (event === WorkerHostEvent.CALL_REQUESTED) {
    return phase === WorkerHostPhase.READY
      ? phaseResult(phase, true)
      : phaseResult(phase, false, "not_initialized");
  }
  return phaseResult(WorkerHostPhase.FAILED, false, "unhandled_known_event");
}

export function initialDemoState() {
  return freeze({ phase: DemoPhase.INITIALIZING });
}

export function isValidDemoState(state) {
  return isRecord(state) && DEMO_PHASES.has(state.phase);
}

export function reduceDemoLifecycle(state, event) {
  if (!isValidDemoState(state) || !DEMO_EVENTS.has(event)) {
    return phaseResult(DemoPhase.FAILED, false, "invalid_transition_input");
  }
  if (state.phase === DemoPhase.FAILED) {
    return phaseResult(state.phase, false, "terminal");
  }
  if (state.phase !== DemoPhase.INITIALIZING) {
    return phaseResult(DemoPhase.FAILED, false, "invalid_internal_event");
  }
  if (event === DemoEvent.INITIALIZED) {
    return phaseResult(DemoPhase.READY, true);
  }
  if (event === DemoEvent.INITIALIZATION_FAILED) {
    return phaseResult(DemoPhase.FAILED, true);
  }
  return phaseResult(DemoPhase.FAILED, false, "unhandled_known_event");
}
