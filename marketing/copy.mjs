// Per-locale marketing copy. One language per asset — never mixed.
// Voice: the app's own deadpan — universal jokes, zero ad-speak, no
// personal statistics. The screenshots carry the demo data.
export const COPY = {
  en: {
    langTag: "en",
    displayFont: '"Futura", "Avenir Next", sans-serif',
    bodyFont: '"Avenir Next", "Futura", sans-serif',
    kickerTracking: "0.34em",
    wordmark: "Meter Beater",
    version: "v1.1.0 · macOS 15+",
    tagline: "Your subscription's odometer",
    shots: {
      hero: {
        kicker: "AN HONEST ADVERTISEMENT",
        headline: "You do not\nneed this app.",
        size: 150,
        sub: "Nobody does.",
        panel: "en-light.png",
        variant: "cream"
      },
      night: {
        kicker: "SOMEWHERE IN SAN FRANCISCO",
        headline: "They priced it\nat $200 a month.",
        size: 136,
        sub: "They believed in you. Look what you did.",
        panel: "en-dark.png",
        variant: "night"
      },
      tiers: {
        kicker: "ALSO",
        headline: "It also\ninsults you.",
        size: 160,
        sub: "Lovingly. In two languages.",
        panel: "en-30d.png",
        toast: "en-toast.png",
        variant: "pasture"
      },
      local: {
        kicker: "PRIVACY POLICY, FULL TEXT",
        headline: "It doesn't\nhave internet.",
        size: 150,
        sub: "That's it. That's the policy.",
        panel: "en-light.png",
        variant: "cream"
      }
    },
    banner: {
      kicker: "FOR CODEX + CLAUDE CODE",
      wordmark: "Meter Beater",
      tagline: "Your subscription's odometer.",
      sub: "Local · private · smug"
    }
  },
  zh: {
    langTag: "zh-Hans",
    displayFont: '"PingFang SC", "Hiragino Sans GB", sans-serif',
    bodyFont: '"PingFang SC", "Hiragino Sans GB", sans-serif',
    kickerTracking: "0.5em",
    wordmark: "羊毛计",
    version: "v1.1.0 · macOS 15+",
    tagline: "你的订阅里程表",
    shots: {
      hero: {
        kicker: "诚实广告",
        headline: "你不需要\n这个应用。",
        size: 160,
        sub: "谁都不需要。",
        panel: "zh-light.png",
        variant: "cream"
      },
      night: {
        kicker: "旧金山某处",
        headline: "他们定价，\n每月 $200。",
        size: 150,
        sub: "他们相信过你。看看你干的好事。",
        panel: "zh-dark.png",
        variant: "night"
      },
      tiers: {
        kicker: "另外",
        headline: "它还会\n骂你。",
        size: 190,
        sub: "用爱骂的。中英双语。",
        panel: "zh-30d.png",
        toast: "zh-toast.png",
        variant: "pasture"
      },
      local: {
        kicker: "隐私政策全文",
        headline: "它压根\n不联网。",
        size: 180,
        sub: "完了。政策就这些。",
        panel: "zh-light.png",
        variant: "cream"
      }
    },
    banner: {
      kicker: "羊毛党专用仪表",
      wordmark: "羊毛计",
      tagline: "你的订阅里程表。",
      sub: "本地 · 私密 · 得意"
    }
  }
};
