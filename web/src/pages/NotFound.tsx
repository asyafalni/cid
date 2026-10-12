import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from '@tanstack/react-router';
import { Airship } from '../Airship';

// Lost in the clouds (docs/dashboard.md §3.1, one of the two easter
// eggs): an address the dashboard has no page for, or a dataset the
// server does not know (or will not show this person). Says what
// happened, then offers the way back: a search and the home.
export function NotFound({ what, next }: { what?: string; next?: string | null }) {
  const navigate = useNavigate();
  const [q, setQ] = useState('');
  const submit = (e: FormEvent) => {
    e.preventDefault();
    void navigate({ to: '/', search: q.trim() === '' ? {} : { q: q.trim() } });
  };
  return (
    <section className="lost sky-band" aria-labelledby="lost-title">
      <Airship className="lost-airship" />
      <h1 id="lost-title">Lost in the clouds</h1>
      <p className="lost-what">{what ?? 'There is no page at this address.'}</p>
      {next && <p className="lost-next">{next}</p>}
      <form className="lost-search" role="search" onSubmit={submit}>
        <input
          type="search"
          aria-label="Search datasets"
          placeholder="Search datasets"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        <button type="submit" className="action">
          Search
        </button>
      </form>
      <Link to="/" className="lost-home">
        All datasets
      </Link>
    </section>
  );
}
