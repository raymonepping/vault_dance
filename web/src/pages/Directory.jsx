// pages/Directory.jsx: the LDAP secrets engine. Root-managed roles rotate
// through cn=vault-rotator (it may write userPassword under
// ou=service-accounts and nothing else); a self-managed role rotates with its
// own password on its own mount.
import { useResource } from '../hooks.js';
import { Authority, ErrorNotice, Loading, Mono } from '../components/ui.jsx';
import { Actions, ProofCell, RotationState, Schedule, Timing, UnlockProbe } from '../components/creds.jsx';
import { when } from '../format.js';

function Health({ h }) {
  if (!h) return <span className="dim">not run yet</span>;
  if (h.error) return <span className="dim">{h.error}</span>;
  const check = h.health_checks?.[0];
  return (
    <span className="cell-stack">
      {h.healthy ? <span className="vg-pill vg-pill--healthy">healthy</span> : <span className="vg-pill vg-pill--rejected">unhealthy</span>}
      <span className="dim">{check?.reason_details || check?.reason || h.reason}</span>
      <span className="dim">{when(h.timestamp)}</span>
    </span>
  );
}

function Roles({ title, sub, rows, reload, id }) {
  return (
    <section className="vg-card stack" aria-labelledby={id}>
      <div className="card-head">
        <h3 id={id}>{title}</h3>
      </div>
      <p className="card-sub">{sub}</p>
      <div className="table-scroll">
        <table className="vg-table">
          <thead>
            <tr>
              <th scope="col">Service account</th>
              <th scope="col">Schedule and policy</th>
              <th scope="col">When</th>
              <th scope="col">State</th>
              <th scope="col">Health check</th>
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
                    <span className="dim">{c.dn}</span>
                  </span>
                </th>
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
                  <Health h={c.healthCheck} />
                </td>
                <td>
                  {c.schedule?.kind === 'on-read' && !c.proof ? <span className="dim">proved on check-out (reading it rotates it)</span> : <ProofCell proof={c.proof} />}
                </td>
                <td>
                  <Actions c={c} onDone={reload} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export default function Directory() {
  const r = useResource('credentials', '/api/credentials', { intervalMs: 5000 });
  const ldap = (r.data?.credentials || []).filter((c) => c.engine === 'ldap');
  const reload = () => r.reload();
  return (
    <>
      <section className="vg-hero" aria-labelledby="dir-hero">
        <div className="hero-grid">
          <div>
            <h2 id="dir-hero" className="hero-title">
              Service accounts, rotated by Vault.
            </h2>
            <p className="hero-lede">
              OpenLDAP at <code>dc=dance,dc=lab</code>. Root-managed roles rotate through a bind that may only write service-account passwords; the self-managed role rotates with its own credentials. A health check binds as the role to prove Vault's password works.
            </p>
          </div>
          <div className="hero-tiles">
            <div className="vg-tile">
              <span className="vg-tile__label">Static roles</span>
              <span className="vg-tile__value num">{ldap.length || '–'}</span>
            </div>
            <div className="vg-tile">
              <span className="vg-tile__label">Healthy</span>
              <span className="vg-tile__value num">{r.data ? ldap.filter((c) => c.healthCheck?.healthy).length : '–'}</span>
            </div>
          </div>
        </div>
      </section>
      <Authority
        actions={[
          ['view', 'see'],
          ['ldap.rotate', 'rotate'],
          ['ldap.checkout', 'check out'],
          ['ldap.healthcheck', 'health check'],
          ['ldap.reregister', 're-register'],
        ]}
      />
      {r.error && <ErrorNotice error={r.error} />}
      {!r.data && !r.error && <Loading />}
      {r.data && (
        <>
          <Roles
            id="root-h"
            title="Root-managed (mount ldap/)"
            sub="Vault binds as cn=vault-rotator,ou=system. Three behaviours: a period (svc-billing), rotate on read with a cooldown (svc-reports), and a cron schedule in UTC (svc-batch)."
            rows={ldap.filter((c) => c.mount === 'ldap')}
            reload={reload}
          />
          <Roles
            id="self-h"
            title="Self-managed (mount ldap-self/)"
            sub="A self_managed mount has no bind credential at all. Each role holds its own current password and changes it by binding as itself; the directory allows that with a by-self-write rule."
            rows={ldap.filter((c) => c.mount === 'ldap-self')}
            reload={reload}
          />
          <section className="vg-card stack" aria-labelledby="unlock-h">
            <h3 id="unlock-h">Account unlock</h3>
            <p className="card-sub">
              Vault 2.2 can clear a login lockout on a root-managed role, for Active Directory only (schema <Mono>ad</Mono>). This directory is OpenLDAP, so Vault refuses; the button asks anyway and shows the answer.
            </p>
            <UnlockProbe id="ldap/svc-billing" />
          </section>
        </>
      )}
    </>
  );
}
