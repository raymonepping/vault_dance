// pages/Orphans.jsx: rotation policies, and what Vault does when a rotation
// keeps failing. The orphan list is shown verbatim, and next to it the
// lab's reading of it: Vault 2.2.1 keeps an orphan record after the fix.
import { useResource } from '../hooks.js';
import { Authority, ErrorNotice, Loading, Mono } from '../components/ui.jsx';
import { Actions, RotationState } from '../components/creds.jsx';

export default function Orphans() {
  const p = useResource('policies', '/api/policies', { intervalMs: 30000 });
  const r = useResource('credentials', '/api/credentials', { intervalMs: 5000 });
  const list = r.data?.credentials || [];
  const listed = r.data?.orphans || [];
  const byRotationId = Object.fromEntries(list.map((c) => [c.rotationId, c]));
  const reload = () => r.reload();
  const attention = list.filter((c) => ['overdue', 'orphaned', 'recovered'].includes(c.state));

  return (
    <>
      <section className="vg-hero" aria-labelledby="orph-hero">
        <div className="hero-grid">
          <div>
            <h2 id="orph-hero" className="hero-title">
              Retry, back off, then stop and say so.
            </h2>
            <p className="hero-lede">
              A rotation that fails is retried with growing pauses, up to the policy's retries per cycle, then requeued to its next scheduled time, up to the policy's cycles. After that Vault stops rotating the credential and lists it in <code>sys/rotation/orphans</code>: no lockout, and an explicit state.
            </p>
          </div>
          <div className="hero-tiles">
            <div className="vg-tile">
              <span className="vg-tile__label">Listed by Vault</span>
              <span className="vg-tile__value num">{r.data ? listed.length : '–'}</span>
            </div>
            <div className="vg-tile">
              <span className="vg-tile__label">Orphaned now</span>
              <span className="vg-tile__value num">{r.data ? list.filter((c) => c.state === 'orphaned').length : '–'}</span>
            </div>
          </div>
        </div>
      </section>
      <Authority
        actions={[
          ['view', 'see'],
          ['os.reregister', 're-register (Linux)'],
          ['ldap.reregister', 're-register (directory)'],
          ['policy.edit', 'change a rotation policy'],
        ]}
      />

      <section className="vg-card stack" aria-labelledby="pol-h">
        <h3 id="pol-h">Rotation policies</h3>
        {p.error && <ErrorNotice error={p.error} />}
        {!p.data && !p.error && <Loading />}
        {p.data && (
          // Focusable: on a phone this table scrolls sideways and holds no buttons.
          <div className="table-scroll" tabIndex={0} role="region" aria-label="Rotation policies table">
            <table className="vg-table">
              <thead>
                <tr>
                  <th scope="col">Policy</th>
                  <th scope="col">Retries per cycle</th>
                  <th scope="col">Cycles</th>
                  <th scope="col">Used by</th>
                </tr>
              </thead>
              <tbody>
                {p.data.policies.map((x) => (
                  <tr key={x.name}>
                    <th scope="row">
                      <Mono>{x.name}</Mono>
                      {x.builtIn && <span className="dim"> Vault's default</span>}
                    </th>
                    <td className="num">{x.maxRetriesPerCycle}</td>
                    <td className="num">{x.maxRetryCycles}</td>
                    <td>
                      <span className="cell-stack">
                        {x.usedBy.length ? x.usedBy.map((id) => <Mono key={id}>{id}</Mono>) : <span className="dim">nothing</span>}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="card-sub">
          The scenario credentials carry <Mono>quick-step</Mono>. Measured on 2.2.1 with plugin 0.2.2+ent (docs/capabilities.md): an LDAP static role follows it and is orphaned within minutes; an OS account stores it but keeps retrying with Vault's default backoff and was never orphaned.
        </p>
      </section>

      <section className="vg-card stack" aria-labelledby="att-h">
        <h3 id="att-h">Credentials that need attention</h3>
        {r.error && <ErrorNotice error={r.error} />}
        {r.data && attention.length === 0 && <p className="dim">None: every scheduled credential rotates on time.</p>}
        {attention.length > 0 && (
          <div className="table-scroll">
            <table className="vg-table">
              <thead>
                <tr>
                  <th scope="col">Credential</th>
                  <th scope="col">State</th>
                  <th scope="col">Listed by Vault</th>
                  <th scope="col">Actions</th>
                </tr>
              </thead>
              <tbody>
                {attention.map((c) => (
                  <tr key={c.id} className={c.state === 'orphaned' ? 'row--orphaned' : c.state === 'overdue' ? 'row--overdue' : undefined}>
                    <th scope="row">
                      <Mono>{c.id}</Mono>
                    </th>
                    <td>
                      <RotationState state={c.state} />
                    </td>
                    <td>{c.orphanListed ? 'yes' : 'no'}</td>
                    <td>
                      <Actions c={c} onDone={reload} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="vg-card stack" aria-labelledby="raw-h">
        <h3 id="raw-h">What Vault lists</h3>
        <p className="card-sub">
          <Mono>GET sys/rotation/orphans</Mono>, verbatim, from the active node (performance standbys refuse this call). In 2.2.1 an entry stays after the credential was re-registered and rotates again; this console then calls it recovered.
        </p>
        {r.data && listed.length === 0 && <p className="dim">Empty.</p>}
        <ul className="next-list">
          {listed.map((o) => (
            <li key={o}>
              <Mono>{o}</Mono>
              {byRotationId[o] ? <RotationState state={byRotationId[o].state} /> : <span className="dim">not one of this lab's credentials</span>}
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}
