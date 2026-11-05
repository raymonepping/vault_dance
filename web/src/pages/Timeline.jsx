// pages/Timeline.jsx: everything the API's watcher saw, newest first, and
// every action people took. Failures carry Vault's own log line.
import { useState } from 'react';
import { useResource } from '../hooks.js';
import { when } from '../format.js';
import { ErrorNotice, Loading, Mono } from '../components/ui.jsx';

const KINDS = [
  ['', 'everything'],
  ['rotation', 'rotations'],
  ['failure', 'failures'],
  ['overdue', 'overdue'],
  ['orphaned', 'orphaned'],
  ['recovered', 'recovered'],
  ['proof', 'proofs'],
  ['reregister', 're-registers'],
];

function Kind({ e }) {
  if (e.kind === 'proof')
    return e.result === 'PASS' ? <span className="vg-pill vg-pill--healthy">proof PASS</span> : <span className="vg-pill vg-pill--rejected">proof FAIL</span>;
  const cls = {
    rotation: 'vg-pill vg-pill--healthy',
    failure: 'vg-pill vg-pill--rejected',
    overdue: 'vg-pill vg-pill--pending',
    orphaned: 'vg-pill vg-pill--rejected',
    recovered: 'vg-pill vg-pill--approved',
  }[e.kind];
  if (e.result === 'refused') return <span className="vg-pill vg-pill--rejected">{e.kind} refused</span>;
  // People's actions (rotate, checkout, re-register, ...) in action blue.
  return <span className={cls || 'vg-pill vg-pill--approved'}>{e.kind}</span>;
}

export default function Timeline() {
  const [kind, setKind] = useState('');
  const t = useResource(`timeline ${kind}`, `/api/timeline?limit=300${kind ? `&kind=${kind}` : ''}`, { intervalMs: 5000 });
  const events = t.data?.events || [];
  return (
    <>
      <section className="vg-hero" aria-labelledby="tl-hero">
        <h2 id="tl-hero" className="hero-title">
          What happened, in Vault's words.
        </h2>
        <p className="hero-lede">
          The API reads every credential every five seconds and proves each one after it rotates. A failed rotation appears here with the line Vault wrote in its own log. Kept in memory: a restart of the API starts a fresh timeline.
        </p>
      </section>
      <section className="vg-card stack" aria-labelledby="tl-h">
        <div className="card-head">
          <h3 id="tl-h">Events</h3>
          <div className="filters" role="group" aria-label="Show">
            {KINDS.map(([k, label]) => (
              <button key={k || 'all'} type="button" className="chip" aria-pressed={kind === k} onClick={() => setKind(k)}>
                {label}
              </button>
            ))}
          </div>
        </div>
        {t.error && <ErrorNotice error={t.error} />}
        {!t.data && !t.error && <Loading />}
        {t.data && events.length === 0 && <p className="dim">Nothing yet.</p>}
        <ol className="timeline">
          {events.map((e, i) => (
            <li key={`${e.at}-${i}`}>
              <span className="when">{when(e.at)}</span>
              <span>
                <Kind e={e} />
              </span>
              <span className="what">
                <span>
                  <Mono>{e.id || 'watcher'}</Mono>
                  {e.by && <span className="dim"> by {e.by}</span>}
                  {e.fingerprint && (
                    <>
                      {' '}
                      <span className="fp">{e.fingerprint}</span>
                    </>
                  )}
                </span>
                {e.detail && <span className="dim">{e.kind === 'failure' ? `Vault said (${e.node}): ${e.detail}` : e.detail}</span>}
              </span>
            </li>
          ))}
        </ol>
      </section>
    </>
  );
}
