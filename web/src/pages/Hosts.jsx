// pages/Hosts.jsx: the OS secrets engine. One card per host, one row per
// local account: who rotates it, how often, under which policy, and the proof.
import { useState } from 'react';
import { History } from 'lucide-react';
import { useResource } from '../hooks.js';
import { call } from '../api.js';
import { when } from '../format.js';
import { Authority, Drawer, ErrorNotice, Loading, Mono } from '../components/ui.jsx';
import { Actions, ProofCell, RotationState, Schedule, Timing } from '../components/creds.jsx';

const HOSTS = [
  { host: 'host-rocky', label: 'host-rocky', distro: 'Rocky Linux 9', note: 'RHEL-compatible: the documented platform of the OS secrets engine (shadow-utils newer than 4.6).' },
  { host: 'host-ubuntu', label: 'host-ubuntu', distro: 'Ubuntu 24.04', note: 'Outside the documented platform. This lab tests it; the proof column shows what actually happens.' },
];

function Mode({ c }) {
  if (c.mode === 'parent-managed')
    return (
      <span className="cell-stack">
        <span>parent-managed</span>
        <span className="dim">
          by <Mono>{c.parent}</Mono> (sudo chpasswd)
        </span>
      </span>
    );
  return (
    <span className="cell-stack">
      <span>self-managed</span>
      <span className="dim">{c.account === 'mgmt-vault' ? 'the parent account; passwd over a PTY' : 'passwd over a PTY'}</span>
    </span>
  );
}

function Versions({ id, onClose }) {
  const v = useResource(`versions ${id}`, `/api/credential?id=${encodeURIComponent(id)}`);
  const versions = v.data?.versions?.versions || {};
  return (
    <Drawer open title={`Versions of ${id}`} onClose={onClose}>
      <p className="drawer-intro">Vault keeps the last versions of each password (max_versions). Restoring one changes only Vault's record, never the host, so this console does not offer it.</p>
      {v.error && <ErrorNotice error={v.error} />}
      {!v.data && !v.error && <Loading />}
      {v.data && (
        <table className="vg-table">
          <thead>
            <tr>
              <th scope="col">Version</th>
              <th scope="col">Created</th>
              <th scope="col">Replaced</th>
            </tr>
          </thead>
          <tbody>
            {Object.entries(versions)
              .sort((a, b) => Number(b[0]) - Number(a[0]))
              .map(([n, x]) => (
                <tr key={n}>
                  <td className="num">
                    {n}
                    {Number(n) === v.data.versions.current_version && <span className="dim"> current</span>}
                  </td>
                  <td>{when(x.created_time)}</td>
                  <td>{x.expired_time?.startsWith('0001-') ? '–' : when(x.expired_time)}</td>
                </tr>
              ))}
          </tbody>
        </table>
      )}
    </Drawer>
  );
}

function HostCard({ meta, rows, reload }) {
  const [versionsOf, setVersionsOf] = useState(null);
  return (
    <section className="vg-card stack" aria-labelledby={`${meta.host}-h`}>
      <div className="card-head">
        <h3 id={`${meta.host}-h`}>
          {meta.label} <span className="dim">· {meta.distro}</span>
        </h3>
      </div>
      <p className="card-sub">{meta.note} Host key pinned in Vault (ssh_host_key), never trusted on first use.</p>
      <div className="table-scroll">
        <table className="vg-table">
          <thead>
            <tr>
              <th scope="col">Account</th>
              <th scope="col">Rotated by</th>
              <th scope="col">Schedule and policy</th>
              <th scope="col">When</th>
              <th scope="col">State</th>
              <th scope="col">Proof</th>
              <th scope="col">Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((c) => (
              <tr key={c.id} className={c.state === 'orphaned' ? 'row--orphaned' : c.state === 'overdue' ? 'row--overdue' : undefined}>
                <th scope="row">
                  <span className="cell-stack">
                    <Mono>{c.account}</Mono>
                    <button type="button" className="vg-btn vg-btn--ghost" onClick={() => setVersionsOf(c.id)}>
                      <History size={12} aria-hidden="true" /> version {c.version ?? '–'}
                    </button>
                  </span>
                </th>
                <td>
                  <Mode c={c} />
                </td>
                <td>
                  <span className="cell-stack">
                    <Schedule schedule={c.schedule} />
                    <span className="dim">policy {c.rotationPolicy || '–'}</span>
                  </span>
                </td>
                <td>
                  <Timing c={c} />
                </td>
                <td>
                  <RotationState state={c.state} />
                </td>
                <td>
                  <ProofCell proof={c.proof} />
                </td>
                <td>
                  <Actions c={c} onDone={reload} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {versionsOf && <Versions id={versionsOf} onClose={() => setVersionsOf(null)} />}
    </section>
  );
}

export default function Hosts() {
  const r = useResource('credentials', '/api/credentials', { intervalMs: 5000 });
  const os = (r.data?.credentials || []).filter((c) => c.engine === 'os');
  const reload = () => r.reload();
  return (
    <>
      <section className="vg-hero" aria-labelledby="hosts-hero">
        <div className="hero-grid">
          <div>
            <h2 id="hosts-hero" className="hero-title">
              Local passwords that change on time.
            </h2>
            <p className="hero-lede">
              The OS secrets engine logs in over SSH with the password it holds. A self-managed account runs <code>passwd</code> itself; a parent-managed one is changed by <code>mgmt-vault</code>, which may run exactly one command as root: <code>/usr/sbin/chpasswd</code>.
            </p>
          </div>
          <div className="hero-tiles">
            <div className="vg-tile">
              <span className="vg-tile__label">Accounts</span>
              <span className="vg-tile__value num">{os.length || '–'}</span>
            </div>
            <div className="vg-tile">
              <span className="vg-tile__label">Proved</span>
              <span className="vg-tile__value num">{r.data ? os.filter((c) => c.proof?.ok).length : '–'}</span>
            </div>
          </div>
        </div>
      </section>
      <Authority
        actions={[
          ['view', 'see'],
          ['os.rotate', 'rotate'],
          ['os.checkout', 'check out break-glass'],
          ['os.reregister', 're-register'],
        ]}
      />
      {r.error && <ErrorNotice error={r.error} />}
      {!r.data && !r.error && <Loading />}
      {r.data &&
        HOSTS.map((h) => (
          <HostCard key={h.host} meta={h} rows={os.filter((c) => c.host === h.host)} reload={reload} />
        ))}
    </>
  );
}
