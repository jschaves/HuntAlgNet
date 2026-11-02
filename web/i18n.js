export const SUPPORTED_LOCALES = [
  "en-US",
  "es-ES",
  "fr-FR",
  "it-IT",
  "de-DE",
  "zh-CN",
  "ja-JP",
  "pt-PT",
  "ar-SA",
  "ru-RU",
];

export const DEFAULT_LOCALE = "en-US";
export const RTL_LOCALES = new Set(["ar-SA"]);

const PRIMARY_ALIASES = {
  en: "en-US",
  es: "es-ES",
  fr: "fr-FR",
  it: "it-IT",
  de: "de-DE",
  zh: "zh-CN",
  ja: "ja-JP",
  pt: "pt-PT",
  ar: "ar-SA",
  ru: "ru-RU",
};

function candidateKey(value) {
  return String(value || "").trim().replace(/_/g, "-").toLowerCase();
}

export function normalizeLocale(value) {
  const candidate = candidateKey(value);
  if (!candidate) return null;

  for (const locale of SUPPORTED_LOCALES) {
    if (locale.toLowerCase() === candidate) return locale;
  }

  const primary = candidate.split("-")[0];
  return PRIMARY_ALIASES[primary] || null;
}

export function resolveBrowserLocale(
  languages = navigator.languages || [navigator.language],
) {
  for (const language of languages) {
    const locale = normalizeLocale(language);
    if (locale) return locale;
  }
  return DEFAULT_LOCALE;
}

export function resolveLocale({ userLocale = null, authenticated = false } = {}) {
  if (authenticated) {
    const saved = normalizeLocale(userLocale);
    if (saved) return saved;
  }
  return resolveBrowserLocale();
}

export function isRtl(locale) {
  return RTL_LOCALES.has(normalizeLocale(locale));
}

export function localeHeaders(locale) {
  return { "Accept-Language": normalizeLocale(locale) || DEFAULT_LOCALE };
}

export function applyDocumentLocale(locale) {
  const code = normalizeLocale(locale) || DEFAULT_LOCALE;
  document.documentElement.lang = code;
  document.documentElement.dir = isRtl(code) ? "rtl" : "ltr";
  return code;
}

export async function loadCatalog(locale, apiBase = "/api/v1") {
  const code = normalizeLocale(locale) || DEFAULT_LOCALE;
  const response = await fetch(`${apiBase}/i18n/${code}`, {
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error(`Unable to load locale catalog: ${code}`);
  }
  return response.json();
}

export function createTranslator(messages, fallbackMessages = {}) {
  return function translate(key, params = {}) {
    const template = messages[key] ?? fallbackMessages[key] ?? key;
    return String(template).replace(/\{(\w+)\}/g, (match, name) =>
      Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : match,
    );
  };
}

export function formatDate(value, locale, options = {}) {
  const code = normalizeLocale(locale) || DEFAULT_LOCALE;
  return new Intl.DateTimeFormat(code, options).format(
    value instanceof Date ? value : new Date(value),
  );
}

export function formatNumber(value, locale, options = {}) {
  const code = normalizeLocale(locale) || DEFAULT_LOCALE;
  return new Intl.NumberFormat(code, options).format(value);
}

export function formatCurrency(value, locale, currency, options = {}) {
  const code = normalizeLocale(locale) || DEFAULT_LOCALE;
  return new Intl.NumberFormat(code, {
    style: "currency",
    currency,
    ...options,
  }).format(value);
}

export function formatRelative(value, locale, unit = "day", options = {}) {
  const code = normalizeLocale(locale) || DEFAULT_LOCALE;
  return new Intl.RelativeTimeFormat(code, options).format(value, unit);
}

export async function initI18n({
  userLocale = null,
  authenticated = false,
  apiBase = "/api/v1",
} = {}) {
  const locale = applyDocumentLocale(
    resolveLocale({ userLocale, authenticated }),
  );
  const catalog = await loadCatalog(locale, apiBase);
  const fallback = locale === DEFAULT_LOCALE ? {} : await loadCatalog(DEFAULT_LOCALE, apiBase);

  return {
    locale,
    direction: isRtl(locale) ? "rtl" : "ltr",
    messages: catalog.messages,
    t: createTranslator(catalog.messages, fallback.messages || {}),
    formatDate: (value, options) => formatDate(value, locale, options),
    formatNumber: (value, options) => formatNumber(value, locale, options),
    formatCurrency: (value, currency, options) => formatCurrency(value, locale, currency, options),
    formatRelative: (value, unit, options) => formatRelative(value, locale, unit, options),
  };
}

export async function saveUserLocale(locale, { apiBase = "/api/v1", token } = {}) {
  const code = normalizeLocale(locale);
  if (!code) throw new Error("Unsupported locale");

  const response = await fetch(`${apiBase}/auth/me/locale`, {
    method: "PATCH",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ locale: code }),
  });
  if (!response.ok) {
    throw new Error("Unable to save locale");
  }
  return response.json();
}
