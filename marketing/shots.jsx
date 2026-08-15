// Launch-shot design system. Vintage seed-packet meets digital odometer:
// flat brand fields, editorial asymmetry, ghost seven-segment numerals,
// wool-scallop base strip, film grain. One language per shot, never mixed.
import { COPY } from "./copy.mjs";

const T = {
  wool: "#FAF7F0",
  woolInk: "#33302C",
  woolInkSoft: "rgba(51, 48, 44, 0.64)",
  pasture: "#2E8B44",
  pastureDeep: "#1E6330",
  pastureInk: "#FAF7F0",
  pastureInkSoft: "rgba(250, 247, 240, 0.78)",
  night: "#0E1A12",
  nightDeep: "#081009",
  lcdGlow: "#71EC7A",
  amber: "#FFB84D",
  mono: '"Menlo", monospace'
};

const VARIANTS = {
  cream: {
    bg: T.wool,
    ink: T.woolInk,
    inkSoft: T.woolInkSoft,
    kicker: T.pasture,
    rule: T.pasture,
    ghost: "rgba(51, 48, 44, 0.05)",
    band: T.pastureDeep,
    grainBlend: "multiply"
  },
  night: {
    bg: T.night,
    ink: T.wool,
    inkSoft: "rgba(250, 247, 240, 0.62)",
    kicker: T.lcdGlow,
    rule: T.lcdGlow,
    ghost: "rgba(113, 236, 122, 0.06)",
    band: T.nightDeep,
    grainBlend: "overlay"
  },
  pasture: {
    bg: T.pasture,
    ink: T.pastureInk,
    inkSoft: T.pastureInkSoft,
    kicker: T.wool,
    rule: T.wool,
    ghost: "rgba(250, 247, 240, 0.09)",
    band: T.pastureDeep,
    grainBlend: "multiply"
  }
};

const GRAIN =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='240' height='240'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.5'/%3E%3C/svg%3E\")";

function Grain({ variant }) {
  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        backgroundImage: GRAIN,
        opacity: 0.05,
        mixBlendMode: VARIANTS[variant].grainBlend,
        zIndex: 9,
        pointerEvents: "none"
      }}
    />
  );
}

/** Slim solid base band anchoring the composition. */
function BaseBand({ variant }) {
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 0,
        height: 56,
        background: VARIANTS[variant].band,
        zIndex: 4
      }}
    />
  );
}

function Kicker({ locale, variant, children }) {
  const v = VARIANTS[variant];
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 26 }}>
      <div style={{ width: 66, height: 7, background: v.rule, borderRadius: 4 }} />
      <div
        style={{
          fontFamily: locale.displayFont,
          fontWeight: 600,
          fontSize: 31,
          letterSpacing: locale.kickerTracking,
          color: v.kicker
        }}
      >
        {children}
      </div>
    </div>
  );
}

function Lockup({ locale, variant, iconSrc }) {
  const v = VARIANTS[variant];
  return (
    <div style={{ position: "absolute", left: 190, bottom: 148, display: "flex", alignItems: "center", gap: 28, zIndex: 5 }}>
      <img src={iconSrc} width={88} height={88} style={{ borderRadius: 22, boxShadow: "0 10px 26px rgba(0,0,0,0.22)" }} />
      <div>
        <div style={{ fontFamily: locale.displayFont, fontWeight: 700, fontSize: 40, color: v.ink }}>
          {locale.wordmark}
        </div>
        <div style={{ fontFamily: T.mono, fontSize: 24, color: v.inkSoft, marginTop: 6 }}>{locale.version}</div>
      </div>
    </div>
  );
}

function Panel({ src, height = 1560, rotate = -1.2 }) {
  return (
    <div
      style={{
        position: "absolute",
        right: 168,
        top: 118,
        transform: `rotate(${rotate}deg)`,
        borderRadius: 30,
        overflow: "hidden",
        boxShadow: "0 70px 140px rgba(8, 16, 10, 0.35), 0 12px 34px rgba(8, 16, 10, 0.22), 0 0 0 1px rgba(20, 20, 16, 0.14)",
        zIndex: 2
      }}
    >
      <img src={src} style={{ display: "block", height }} />
    </div>
  );
}

export function LaunchShot({ locale, shot, iconSrc }) {
  const v = VARIANTS[shot.variant];
  const zh = locale.langTag !== "en";
  const headlineLines = shot.headline.split("\n");
  return (
    <div
      lang={locale.langTag}
      style={{
        position: "relative",
        width: 2880,
        height: 1800,
        background: v.bg,
        overflow: "hidden",
        WebkitFontSmoothing: "antialiased"
      }}
    >
      <Panel src={shot.panel} />
      {shot.toast ? (
        <div
          style={{
            position: "absolute",
            left: 1180,
            bottom: 300,
            transform: "rotate(1.8deg)",
            zIndex: 3,
            boxShadow: "0 40px 90px rgba(8, 16, 10, 0.45)",
            borderRadius: 10
          }}
        >
          <img src={shot.toast} style={{ display: "block", height: 330 }} />
        </div>
      ) : null}

      <div style={{ position: "absolute", left: 190, top: 300, width: 1180, zIndex: 5 }}>
        <Kicker locale={locale} variant={shot.variant}>
          {shot.kicker}
        </Kicker>
        <div
          style={{
            marginTop: 66,
            fontFamily: locale.displayFont,
            fontWeight: 700,
            fontSize: shot.size ?? (zh ? 168 : 186),
            lineHeight: zh ? 1.18 : 1.02,
            letterSpacing: zh ? "0.01em" : "-0.015em",
            color: v.ink
          }}
        >
          {headlineLines.map((line, index) => (
            <div key={index}>{line}</div>
          ))}
        </div>
        <div
          style={{
            marginTop: 62,
            fontFamily: locale.bodyFont,
            fontWeight: 500,
            fontSize: 41,
            lineHeight: 1.55,
            maxWidth: 940,
            color: v.inkSoft
          }}
        >
          {shot.sub}
        </div>
      </div>

      <Lockup locale={locale} variant={shot.variant} iconSrc={iconSrc} />
      <BaseBand variant={shot.variant} />
      <Grain variant={shot.variant} />
    </div>
  );
}

export function Banner({ locale, iconSrc }) {
  const v = VARIANTS.cream;
  const zh = locale.langTag !== "en";
  const banner = locale.banner;
  return (
    <div
      lang={locale.langTag}
      style={{
        position: "relative",
        width: 1600,
        height: 900,
        background: v.bg,
        overflow: "hidden",
        WebkitFontSmoothing: "antialiased"
      }}
    >
      <img
        src={iconSrc}
        width={470}
        height={470}
        style={{
          position: "absolute",
          left: 120,
          top: 172,
          borderRadius: 106,
          boxShadow: "0 44px 90px rgba(8, 16, 10, 0.28)",
          zIndex: 2
        }}
      />
      <div style={{ position: "absolute", left: 680, top: zh ? 218 : 250, zIndex: 3 }}>
        <Kicker locale={locale} variant="cream">
          {banner.kicker}
        </Kicker>
        <div
          style={{
            marginTop: 42,
            fontFamily: locale.displayFont,
            fontWeight: 700,
            fontSize: zh ? 214 : 122,
            lineHeight: 1.04,
            letterSpacing: zh ? "0.03em" : "-0.01em",
            color: v.ink
          }}
        >
          {banner.wordmark}
        </div>
        <div
          style={{
            marginTop: zh ? 40 : 34,
            fontFamily: locale.bodyFont,
            fontWeight: 500,
            fontSize: 44,
            color: v.inkSoft
          }}
        >
          {banner.tagline}
        </div>
        <div
          style={{
            marginTop: 22,
            fontFamily: zh ? locale.bodyFont : T.mono,
            fontSize: 30,
            letterSpacing: zh ? "0.2em" : "0.08em",
            color: VARIANTS.cream.kicker,
            fontWeight: 600
          }}
        >
          {banner.sub}
        </div>
      </div>
      <BaseBand variant="cream" />
      <Grain variant="cream" />
    </div>
  );
}

/** Manifest consumed by build.mjs: every rendered artifact, both locales. */
export function manifest(iconSrc) {
  const jobs = [];
  for (const key of ["en", "zh"]) {
    const locale = COPY[key];
    for (const [name, shot] of Object.entries(locale.shots)) {
      jobs.push({
        name: `shot-${key}-${name}`,
        width: 2880,
        height: 1800,
        element: (
          <LaunchShot
            locale={locale}
            iconSrc={iconSrc}
            shot={{ ...shot, panel: `captures/${key}-${shot.panel.replace(`${key}-`, "")}`, toast: shot.toast ? `captures/${shot.toast}` : null }}
          />
        )
      });
    }
    jobs.push({
      name: `banner-${key}`,
      width: 1600,
      height: 900,
      element: <Banner locale={locale} iconSrc={iconSrc} />
    });
  }
  return jobs;
}
