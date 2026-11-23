import { useEffect, useState } from 'react';
import type { StateAnnotation } from './api';
import { classColor, clock, parseTime, type TimeRange } from './shapes';

// An audio or video item's time annotations, under its player: one lane
// per class with each segment where it falls, and the transcript as
// lines. A segment or a line seeks the player to where it starts; the
// line being heard is marked. Without a player (a restricted item before
// its reveal) they are drawn all the same, only not clickable.

type Timed = TimeRange & { id: string; cls: string | null; transcript: boolean };

export function MediaTimeline({
  annotations,
  hidden,
  media,
}: {
  annotations: StateAnnotation[];
  hidden: ReadonlySet<string>;
  media: HTMLMediaElement | null;
}) {
  const [duration, setDuration] = useState<number | null>(null);
  const [now, setNow] = useState(0);
  useEffect(() => {
    if (!media) return;
    const meta = () => setDuration(Number.isFinite(media.duration) && media.duration > 0 ? media.duration : null);
    const tick = () => setNow(media.currentTime);
    meta();
    media.addEventListener('loadedmetadata', meta);
    media.addEventListener('durationchange', meta);
    media.addEventListener('timeupdate', tick);
    media.addEventListener('seeked', tick);
    return () => {
      media.removeEventListener('loadedmetadata', meta);
      media.removeEventListener('durationchange', meta);
      media.removeEventListener('timeupdate', tick);
      media.removeEventListener('seeked', tick);
    };
  }, [media]);

  const timed: Timed[] = [];
  let unread = 0;
  for (const a of annotations) {
    if (a.kind !== 'segment' && a.kind !== 'transcript') continue;
    const t = parseTime(a);
    if (!t) {
      unread++;
      continue;
    }
    if (a.class !== null && hidden.has(a.class)) continue;
    timed.push({ ...t, id: a.id, cls: a.class, transcript: a.kind === 'transcript' });
  }
  if (timed.length === 0 && unread === 0) return null;
  timed.sort((x, y) => x.start - y.start || x.end - y.end);

  // The scale: the media's own length once known, else the last end.
  const span = Math.max(duration ?? 0, ...timed.map((t) => t.end), 0.001);
  const lanes = new Map<string, Timed[]>();
  for (const t of timed) {
    if (t.transcript) continue;
    const key = t.cls ?? '—';
    lanes.set(key, [...(lanes.get(key) ?? []), t]);
  }
  const lines = timed.filter((t) => t.transcript);
  const seek = (t: number) => {
    if (!media) return;
    // The player is a DOM element, not React state: seeking it is the point.
    // oxlint-disable-next-line react/immutability
    media.currentTime = t;
    void media.play().catch(() => {});
  };
  const label = (t: Timed) => `${t.cls ?? 'no class'}, ${clock(t.start)} to ${clock(t.end)}`;

  return (
    <section className="media-timeline" aria-label="Timeline">
      {lanes.size > 0 && (
        <div className="timeline-lanes">
          {[...lanes].map(([cls, segs]) => (
            <div className="timeline-lane" key={cls}>
              <span className="timeline-class data">
                <span className="class-dot" style={{ background: classColor(cls === '—' ? null : cls) }} />
                {cls}
              </span>
              <span className="timeline-track">
                {segs.map((t) => {
                  const style = {
                    left: `${(t.start / span) * 100}%`,
                    width: `${((t.end - t.start) / span) * 100}%`,
                    background: classColor(t.cls),
                  };
                  return media ? (
                    <button key={t.id} className="timeline-seg" style={style} title={label(t)} aria-label={label(t)} onClick={() => seek(t.start)} />
                  ) : (
                    <span key={t.id} className="timeline-seg" style={style} title={label(t)} />
                  );
                })}
                {media && <span className="timeline-playhead" style={{ left: `${(Math.min(now, span) / span) * 100}%` }} aria-hidden />}
              </span>
            </div>
          ))}
          <div className="timeline-lane" aria-hidden>
            <span />
            <span className="timeline-scale quiet data">
              <span>{clock(0)}</span>
              <span>{clock(span)}</span>
            </span>
          </div>
        </div>
      )}
      {lines.length > 0 && (
        <ol className="transcript" aria-label="Transcript">
          {lines.map((t) => {
            const current = media !== null && now >= t.start && now < t.end;
            const body = (
              <>
                <span className="transcript-time data">{clock(t.start)}</span>
                <span className="transcript-text">{t.text}</span>
              </>
            );
            return (
              <li key={t.id} aria-current={current ? 'true' : undefined} className={current ? 'on' : undefined}>
                {media ? (
                  <button className="transcript-line" onClick={() => seek(t.start)} title={`Play from ${clock(t.start)}`}>
                    {body}
                  </button>
                ) : (
                  <span className="transcript-line">{body}</span>
                )}
              </li>
            );
          })}
        </ol>
      )}
      {unread > 0 && (
        <p className="quiet">
          {unread === 1 ? 'One time annotation' : `${unread} time annotations`} could not be read (a start and an end in
          seconds, the end not before the start); the rest are shown.
        </p>
      )}
    </section>
  );
}
