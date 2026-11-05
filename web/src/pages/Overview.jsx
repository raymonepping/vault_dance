// pages/Overview.jsx: the whole lab at a glance. The cluster, every
// credential's state, the next rotations, the orphans.
import { Server, Network, RefreshCcwDot } from 'lucide-react';
import { useResource } from '../hooks.js';
import { relative } from '../format.js';
import { ErrorNotice, Loading, Mono, StatePill } from '../components/ui.jsx';
import { RotationState } from '../components/creds.jsx';

function Cluster() {
  const c = useResource('cluster', '/api/cluster', { intervalMs: 10000 });
  if (c.error) return <ErrorNotice error={c.error} title="Cluster" />;
  if (!c.data) return <Loading />;
  const d = c.data;
  const voters = d.raft?.filter((s) => s.voter).length ?? '–';
  return (
    <section className="vg-card stack" aria-labelledby="cluster-h">
      <div className="card-head">
        <h3 id="cluster-h">Cluster</h3>
        <span className="card-sub">
          {voters} Raft voters · sealed by <Mono>vault-s</Mono> ({d.seal.sealed ? 'sealed' : 'unsealed'})
        </span>
      </div>
      <div className="nodes">
        <div className="node">
          <span className="node__name">vault-s</span>
          <span className="dim">Transit seal, Shamir</span>
          {d.seal.reachable && !d.seal.sealed ? <StatePill state="ok">unsealed</StatePill> : <StatePill state="denied">{d.seal.reachable ? 'sealed' : 'unreachable'}</StatePill>}
        </div>
        {d.nodes.map((n) => (
          <div className="node" key={n.addr}>
            <span className="node__name">{n.name}</span>
            <span className="dim">{n.active ? 'active (rotation manager)' : n.performanceStandby ? 'performance standby' : n.standby ? 'standby' : '–'}</span>
            {n.reachable && !n.sealed ? <StatePill state={n.active ? 'info' : 'ok'}>{n.version}</StatePill> : <StatePill state="denied">{n.reachable ? 'sealed' : 'unreachable'}</StatePill>}
          </div>
        ))}
      </div>
    </section>
  );
}

export default function Overview() {
  const r = useResource('credentials', '/api/credentials', { intervalMs: 5000 });
  const list = r.data?.credentials || [];
  const count = (pred) => list.filter(pred).length;
  const proved = count((c) => c.proof?.ok);
  const orphaned = count((c) => c.state === 'orphaned');
  const overdue = count((c) => c.state === 'overdue');
  const next = list
    .filter((c) => c.nextRotation && c.schedule?.kind !== 'on-read' && ['ok', 'recovered'].includes(c.state))
    .sort((a, b) => new Date(a.nextRotation) - new Date(b.nextRotation))
    .slice(0, 5);

  return (
    <>
      <section className="vg-hero" aria-labelledby="hero-h">
        <div className="hero-grid">
          <div>
            <h2 id="hero-h" className="hero-title">
              Every credential, proved.
            </h2>
            <p className="hero-lede">
              Vault rotates local Linux passwords and directory passwords on a schedule. After every rotation this console logs in with the password Vault holds now. When a rotation fails, Vault retries, backs off, and finally marks the credential orphaned instead of drifting in silence.
            </p>
          </div>
          <div className="hero-tiles hero-tiles--four">
            <div className="vg-tile">
              <span className="vg-tile__label">Credentials</span>
              <span className="vg-tile__value num">{list.length || '–'}</span>
            </div>
            <div className="vg-tile">
              <span className="vg-tile__label">Last proof PASS</span>
              <span className="vg-tile__value num">{r.data ? proved : '–'}</span>
            </div>
            <div className="vg-tile">
              <span className="vg-tile__label">Overdue</span>
              <span className="vg-tile__value num">{r.data ? overdue : '–'}</span>
            </div>
            <div className="vg-tile">
              <span className="vg-tile__label">Orphaned</span>
              <span className="vg-tile__value num">{r.data ? orphaned : '–'}</span>
            </div>
          </div>
        </div>
      </section>

      <Cluster />

      <div className="grid-2">
        <section className="vg-card stack" aria-labelledby="next-h">
          <h3 id="next-h">Next rotations</h3>
          {r.error && <ErrorNotice error={r.error} />}
          {!r.data && !r.error && <Loading />}
          {r.data && next.length === 0 && <p className="dim">Nothing scheduled on time right now.</p>}
          <ol className="next-list">
            {next.map((c) => (
              <li key={c.id}>
                <Mono>{c.id}</Mono>
                <span className="num">{relative(c.nextRotation)}</span>
              </li>
            ))}
          </ol>
        </section>
        <section className="vg-card stack" aria-labelledby="attn-h">
          <h3 id="attn-h">Needs attention</h3>
          {r.data && list.filter((c) => !['ok', 'on-read'].includes(c.state)).length === 0 && <p className="dim">Nothing: every scheduled credential rotates on time.</p>}
          <ul className="next-list">
            {list
              .filter((c) => !['ok', 'on-read'].includes(c.state))
              .map((c) => (
                <li key={c.id}>
                  <Mono>{c.id}</Mono>
                  <RotationState state={c.state} />
                </li>
              ))}
          </ul>
          <a className="hero-link" href="#/orphans">
            <RefreshCcwDot size={14} aria-hidden="true" /> Retries and orphans
          </a>
        </section>
      </div>

      <div className="grid-2">
        <a className="vg-card stack" href="#/hosts">
          <span className="card-head">
            <Server size={16} aria-hidden="true" />
            <h3>Linux hosts</h3>
          </span>
          <span className="card-sub">The OS secrets engine on Rocky 9 and Ubuntu 24.04: a parent account that may only run chpasswd, and accounts that rotate themselves.</span>
        </a>
        <a className="vg-card stack" href="#/directory">
          <span className="card-head">
            <Network size={16} aria-hidden="true" />
            <h3>Directory</h3>
          </span>
          <span className="card-sub">LDAP static roles: root-managed through a narrow rotator bind, self-managed on their own mount, on a period, a cron schedule, or on read.</span>
        </a>
      </div>
    </>
  );
}
