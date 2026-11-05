// components/creds.jsx: how one rotated credential is shown and acted on.
// Colour only for state (DESIGN.md): proved/ok green, overdue amber,
// orphaned/FAIL red, recovered blue, no schedule grey.
import { useState } from 'react';
import { CircleCheck, CircleX, TriangleAlert, RefreshCw, KeyRound, ShieldCheck, RotateCcw, Stethoscope, LockOpen, Hourglass } from 'lucide-react';
import { call } from '../api.js';
import { relative, when } from '../format.js';
import { ErrorNotice, Locked, Mono } from './ui.jsx';

const STATE = {
  ok: ['vg-pill vg-pill--healthy', CircleCheck, 'on schedule'],
  overdue: ['vg-pill vg-pill--pending', Hourglass, 'overdue: Vault is retrying'],
  orphaned: ['vg-pill vg-pill--rejected', CircleX, 'orphaned: Vault stopped'],
  recovered: ['vg-pill vg-pill--approved', RefreshCw, 'recovered (orphan record kept)'],
  'on-read': ['vg-pill vg-pill--manual', KeyRound, 'rotates on read'],
  manual: ['vg-pill vg-pill--manual', null, 'no schedule'],
  missing: ['vg-pill vg-pill--manual', TriangleAlert, 'not onboarded'],
};

export function RotationState({ state }) {
  const [cls, Icon, label] = STATE[state] || STATE.manual;
  return (
    <span className={cls}>
      {Icon && <Icon size={12} aria-hidden="true" />}
      {label}
    </span>
  );
}

const every = (s) => (s % 3600 === 0 ? `${s / 3600}h` : s % 60 === 0 ? `${s / 60} min` : `${s}s`);

// "*/5 * * * *" in words, for the five-field forms this lab uses.
export function cronWords(cron) {
  const m = /^\*\/(\d+) \* \* \* \*$/.exec(cron || '');
  if (m) return `every ${m[1]} minutes, on the clock (UTC)`;
  if (/^0 \* \* \* \*$/.test(cron || '')) return 'every hour, on the hour (UTC)';
  return 'cron schedule (UTC)';
}

export function Schedule({ schedule }) {
  if (!schedule) return <span className="dim">–</span>;
  if (schedule.kind === 'period') return <span>every {every(schedule.seconds)}</span>;
  if (schedule.kind === 'schedule')
    return (
      <span className="cell-stack">
        <span>{cronWords(schedule.cron)}</span>
        <Mono>{schedule.cron}</Mono>
      </span>
    );
  if (schedule.kind === 'on-read') return <span>on each read, cooldown {every(schedule.cooldown)}</span>;
  return <span className="dim">manual only</span>;
}

export function Timing({ c }) {
  const onRead = c.schedule?.kind === 'on-read';
  return (
    <span className="cell-stack num">
      <span>last {relative(c.lastRotation)}</span>
      {!onRead && <span className={c.state === 'overdue' || c.state === 'orphaned' ? 'dim' : ''}>next {relative(c.nextRotation)}</span>}
    </span>
  );
}

export function ProofCell({ proof }) {
  if (!proof) return <span className="dim">not proved yet</span>;
  return (
    <span className="cell-stack">
      <span>
        {proof.ok ? (
          <span className="vg-pill vg-pill--healthy">
            <CircleCheck size={12} aria-hidden="true" /> PASS
          </span>
        ) : (
          <span className="vg-pill vg-pill--rejected">
            <CircleX size={12} aria-hidden="true" /> FAIL
          </span>
        )}{' '}
        <span className="fp" title="First 8 hex characters of the SHA-256 of the password Vault holds">
          {proof.fingerprint}
        </span>
      </span>
      <span className="dim">{when(proof.at)}</span>
    </span>
  );
}

const enc = (id) => encodeURIComponent(id);

// One action button: runs on the signed-in person's token through the API.
function Act({ id, verb, label, icon: Icon, action, onDone, primary }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [result, setResult] = useState(null);
  const run = async () => {
    setBusy(true);
    setError(null);
    setResult(null);
    try {
      const r = await call(`${label}: ${id}`, `/api/credential/${verb}?id=${enc(id)}`, { method: 'POST' });
      setResult(r);
      onDone?.(r);
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  };
  return (
    <span className="cell-stack">
      <button type="button" className={primary ? 'primary-button' : 'secondary-button'} onClick={run} disabled={busy}>
        <Icon size={13} aria-hidden="true" /> {busy ? 'Working…' : label}
        {action && <Locked action={action} />}
      </button>
      {error && <ErrorNotice error={error} title={`${label} refused`} />}
      {result?.checkout && (
        <span className="result" role="status">
          <span>
            fingerprint <span className="fp">{result.checkout.fingerprint}</span>
            {result.checkout.rotatedOnRead === true && <> · rotated by this read</>}
            {result.checkout.rotatedOnRead === false && <> · inside the cooldown: same password</>}
          </span>
          <span>login {result.proof?.result}</span>
        </span>
      )}
      {result?.proof && !result.checkout && (
        <span className="result" role="status">
          login {result.proof.result} · <span className="fp">{result.proof.fingerprint}</span>
        </span>
      )}
      {result?.result && (
        <span className="result" role="status">
          {result.result.healthy ? 'healthy' : 'unhealthy'}: {result.result.health_checks?.[0]?.reason || result.result.reason}
        </span>
      )}
    </span>
  );
}

// The actions a credential offers. Buttons stay clickable when Vault will
// refuse (the lock predicts it); the refusal is shown verbatim.
export function Actions({ c, onDone }) {
  const os = c.engine === 'os';
  const onRead = c.schedule?.kind === 'on-read';
  const breakglass = os && c.account === 'ops-breakglass';
  return (
    <div className="actions">
      {!onRead && <Act id={c.id} verb="proof" label="Prove" icon={ShieldCheck} onDone={onDone} />}
      <Act id={c.id} verb="rotate" label="Rotate now" icon={RefreshCw} action={os ? 'os.rotate' : 'ldap.rotate'} onDone={onDone} />
      {(onRead || breakglass) && <Act id={c.id} verb="checkout" label="Check out" icon={KeyRound} action={os ? 'os.checkout' : 'ldap.checkout'} onDone={onDone} />}
      {(c.state === 'orphaned' || c.state === 'recovered' || c.state === 'overdue') && (
        <Act id={c.id} verb="reregister" label="Re-register" icon={RotateCcw} action={os ? 'os.reregister' : 'ldap.reregister'} onDone={onDone} primary />
      )}
      {!os && <Act id={c.id} verb="health-check" label="Health check" icon={Stethoscope} action="ldap.healthcheck" onDone={onDone} />}
    </div>
  );
}

export function UnlockProbe({ id }) {
  return <Act id={id} verb="unlock" label="Unlock" icon={LockOpen} action="ldap.unlock" />;
}
