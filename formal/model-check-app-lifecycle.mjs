#!/usr/bin/env node
import assert from "node:assert/strict";

import {
  DemoEvent,
  DemoPhase,
  MainThreadEvent,
  MainThreadPhase,
  WorkerClientEvent,
  WorkerClientPhase,
  WorkerHostEvent,
  WorkerHostPhase,
  initialDemoState,
  initialMainThreadState,
  initialWorkerClientState,
  initialWorkerHostState,
  isValidDemoState,
  isValidMainThreadState,
  isValidWorkerClientState,
  isValidWorkerHostState,
  isWorkerClientTerminal,
  reduceDemoLifecycle,
  reduceMainThreadLifecycle,
  reduceWorkerClientLifecycle,
  reduceWorkerHostLifecycle,
} from "../clients/browser/lifecycle.mjs";

function key(state) {
  return JSON.stringify(state);
}

function assertClosedVocabulary(name, vocabulary) {
  assert.equal(Object.isFrozen(vocabulary), true, `${name} must be frozen`);
  const values = Object.values(vocabulary);
  assert.ok(values.length > 0, `${name} must not be empty`);
  assert.equal(
    new Set(values).size,
    values.length,
    `${name} contains duplicate wire values`,
  );
}

for (const [name, vocabulary] of [
  ["MainThreadPhase", MainThreadPhase],
  ["MainThreadEvent", MainThreadEvent],
  ["WorkerClientPhase", WorkerClientPhase],
  ["WorkerClientEvent", WorkerClientEvent],
  ["WorkerHostPhase", WorkerHostPhase],
  ["WorkerHostEvent", WorkerHostEvent],
  ["DemoPhase", DemoPhase],
  ["DemoEvent", DemoEvent],
]) {
  assertClosedVocabulary(name, vocabulary);
}

function assertDeterministic(reducer, state, event, ...rest) {
  const first = reducer(state, event, ...rest);
  const second = reducer(state, event, ...rest);
  assert.deepEqual(first, second);
  assert.equal(Object.isFrozen(first), true);
  assert.equal(Object.isFrozen(first.state), true);
  assert.deepEqual(Object.keys(first).sort(), ["accepted", "code", "state"]);
  assert.notEqual(
    first.code,
    "unhandled_known_event",
    `declared event is missing an explicit reducer branch: ${event}`,
  );
  return first;
}

function explore(initial, events, reducer, ...rest) {
  const states = new Map([[key(initial), initial]]);
  const queue = [initial];
  let transitions = 0;
  while (queue.length > 0) {
    const state = queue.shift();
    for (const event of events) {
      const outcome = assertDeterministic(reducer, state, event, ...rest);
      transitions += 1;
      const stateKey = key(outcome.state);
      if (!states.has(stateKey)) {
        states.set(stateKey, outcome.state);
        queue.push(outcome.state);
      }
    }
  }
  return { states: [...states.values()], transitions };
}

const mainEvents = Object.values(MainThreadEvent);
const mainGraph = explore(
  initialMainThreadState(),
  mainEvents,
  reduceMainThreadLifecycle,
);
assert.equal(mainGraph.states.length, Object.values(MainThreadPhase).length);
for (const phase of Object.values(MainThreadPhase)) {
  const state = { phase };
  assert.equal(isValidMainThreadState(state), true);
  for (const event of mainEvents) {
    const outcome = assertDeterministic(reduceMainThreadLifecycle, state, event);
    assert.equal(isValidMainThreadState(outcome.state), true);
    if (event === MainThreadEvent.CALL_STARTED) {
      assert.equal(outcome.accepted, phase === MainThreadPhase.READY);
    }
    if (phase === MainThreadPhase.FAILED) {
      assert.equal(outcome.state.phase, MainThreadPhase.FAILED);
    }
  }
}
assert.deepEqual(
  reduceMainThreadLifecycle(
    { phase: MainThreadPhase.CALLING },
    MainThreadEvent.CALL_STARTED,
  ).state,
  { phase: MainThreadPhase.CALLING },
);

const workerEvents = Object.values(WorkerClientEvent);
let workerStates = 0;
let workerTransitions = 0;
for (let limit = 1; limit <= 4; limit += 1) {
  const graph = explore(
    initialWorkerClientState(),
    workerEvents,
    reduceWorkerClientLifecycle,
    limit,
  );
  assert.equal(graph.states.length, 2 * limit + 6);
  workerStates += graph.states.length;
  workerTransitions += graph.transitions;

  const states = [
    { phase: WorkerClientPhase.STARTING, pending: 0 },
    { phase: WorkerClientPhase.STARTING, pending: 1 },
    { phase: WorkerClientPhase.CLOSED, pending: 0 },
    { phase: WorkerClientPhase.FAILED, pending: 0 },
  ];
  for (let pending = 0; pending <= limit; pending += 1) {
    states.push({ phase: WorkerClientPhase.READY, pending });
    states.push({ phase: WorkerClientPhase.DRAINING, pending });
  }

  for (const state of states) {
    assert.equal(isValidWorkerClientState(state, limit), true);
    for (const event of workerEvents) {
      const outcome = assertDeterministic(
        reduceWorkerClientLifecycle,
        state,
        event,
        limit,
      );
      assert.equal(isValidWorkerClientState(outcome.state, limit), true);
      if (event === WorkerClientEvent.REQUEST_STARTED) {
        assert.equal(
          outcome.accepted,
          state.phase === WorkerClientPhase.READY && state.pending < limit,
        );
      }
      if (event === WorkerClientEvent.REQUEST_SETTLED) {
        assert.equal(
          outcome.accepted,
          (state.phase === WorkerClientPhase.READY ||
            state.phase === WorkerClientPhase.DRAINING) &&
            state.pending > 0,
        );
      }
      if (state.phase === WorkerClientPhase.DRAINING) {
        assert.notEqual(outcome.state.phase, WorkerClientPhase.STARTING);
        assert.notEqual(outcome.state.phase, WorkerClientPhase.READY);
      }
      if (isWorkerClientTerminal(state)) {
        assert.equal(outcome.state.phase, state.phase);
        assert.equal(outcome.state.pending, 0);
      }
    }
  }

  for (let pending = 0; pending <= limit; pending += 1) {
    let state = { phase: WorkerClientPhase.DRAINING, pending };
    while (state.pending > 0) {
      const outcome = reduceWorkerClientLifecycle(
        state,
        WorkerClientEvent.REQUEST_SETTLED,
        limit,
      );
      assert.equal(outcome.accepted, true);
      state = outcome.state;
    }
    const completed = reduceWorkerClientLifecycle(
      state,
      WorkerClientEvent.DRAIN_COMPLETED,
      limit,
    );
    assert.deepEqual(completed.state, {
      phase: WorkerClientPhase.CLOSED,
      pending: 0,
    });
  }
}

const hostEvents = Object.values(WorkerHostEvent);
const hostGraph = explore(
  initialWorkerHostState(),
  hostEvents,
  reduceWorkerHostLifecycle,
);
assert.equal(hostGraph.states.length, Object.values(WorkerHostPhase).length);
for (const phase of Object.values(WorkerHostPhase)) {
  const state = { phase };
  assert.equal(isValidWorkerHostState(state), true);
  for (const event of hostEvents) {
    const outcome = assertDeterministic(reduceWorkerHostLifecycle, state, event);
    assert.equal(isValidWorkerHostState(outcome.state), true);
    if (event === WorkerHostEvent.CALL_REQUESTED) {
      assert.equal(outcome.accepted, phase === WorkerHostPhase.READY);
    }
    if (phase === WorkerHostPhase.FAILED) {
      assert.equal(outcome.state.phase, WorkerHostPhase.FAILED);
    }
  }
}

const demoEvents = Object.values(DemoEvent);
const demoGraph = explore(initialDemoState(), demoEvents, reduceDemoLifecycle);
assert.equal(demoGraph.states.length, Object.values(DemoPhase).length);
for (const state of demoGraph.states) {
  assert.equal(isValidDemoState(state), true);
  for (const event of demoEvents) {
    const outcome = assertDeterministic(reduceDemoLifecycle, state, event);
    assert.equal(isValidDemoState(outcome.state), true);
  }
}

assert.equal(
  reduceMainThreadLifecycle({}, MainThreadEvent.FAULT).state.phase,
  MainThreadPhase.FAILED,
);
assert.equal(
  reduceWorkerClientLifecycle(
    { phase: WorkerClientPhase.READY, pending: 5 },
    WorkerClientEvent.FAULT,
    2,
  ).state.phase,
  WorkerClientPhase.FAILED,
);
const invalidHostEvent = reduceWorkerHostLifecycle(initialWorkerHostState(), "unknown");
assert.equal(invalidHostEvent.state.phase, WorkerHostPhase.FAILED);
assert.equal(invalidHostEvent.code, "invalid_transition_input");
const invalidDemoEvent = reduceDemoLifecycle(initialDemoState(), "unknown");
assert.equal(invalidDemoEvent.state.phase, DemoPhase.FAILED);
assert.equal(invalidDemoEvent.code, "invalid_transition_input");

process.stdout.write(
  [
    "application lifecycle model check passed:",
    `main=${mainGraph.states.length} states/${mainGraph.transitions} transitions`,
    `worker=${workerStates} states/${workerTransitions} transitions`,
    `host=${hostGraph.states.length} states/${hostGraph.transitions} transitions`,
    `demo=${demoGraph.states.length} states/${demoGraph.transitions} transitions`,
  ].join(" ") + "\n",
);
