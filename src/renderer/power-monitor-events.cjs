'use strict';
function create({ capacity = 20, now = () => new Date().toISOString() } = {}) {
  if (!Number.isInteger(capacity) || capacity < 1 || typeof now !== 'function') throw new Error('Invalid power event log options');
  const events = [];
  function record(event) {
    if (event !== 'suspend' && event !== 'resume') throw new Error('Unsupported power event');
    const at_utc = now();
    if (typeof at_utc !== 'string' || !Number.isFinite(Date.parse(at_utc))) throw new Error('Invalid power event timestamp');
    events.push({ event, at_utc });
    if (events.length > capacity) events.shift();
    return events.at(-1);
  }
  function attach(monitor) {
    if (!monitor || typeof monitor.on !== 'function') throw new Error('Invalid power monitor');
    const onSuspend = () => record('suspend');
    const onResume = () => record('resume');
    monitor.on('suspend', onSuspend);
    monitor.on('resume', onResume);
    return () => {
      monitor.removeListener?.('suspend', onSuspend);
      monitor.removeListener?.('resume', onResume);
    };
  }
  return { record, attach, snapshot: () => events.map(event => ({ ...event })) };
}
module.exports = { create };
