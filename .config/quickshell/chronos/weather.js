// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// WMO weather interpretation codes, which is the vocabulary open-meteo answers
// in, and the nerd-font glyph each one is drawn with.
//
// Every codepoint below was read off the installed JetBrainsMono Nerd Font
// rather than copied from a cheat sheet, so a glyph here is the glyph that
// actually renders — nf-weather is dense with near-identical clouds and it is
// very easy to end up showing hail for a clear afternoon.

// ── glyphs, day / night ────────────────────────────────────────────────
const SUN         = "";  // wi-day-sunny
const MOON        = "";  // wi-night-clear
const SUN_HAZE    = "";  // wi-day-sunny-overcast
const MOON_HAZE   = "";  // wi-night-cloudy
const SUN_CLOUD   = "";  // wi-day-cloudy
const OVERCAST    = "";  // wi-cloudy
const FOG         = "";  // wi-fog
const SUN_SHOWERS = "";  // wi-day-showers
const MOON_SHOWERS= "";  // wi-night-alt-showers
const SUN_RAIN    = "";  // wi-day-rain
const MOON_RAIN   = "";  // wi-night-alt-rain
const SUN_SLEET   = "";  // wi-day-sleet
const MOON_SLEET  = "";  // wi-night-alt-sleet
const SUN_SNOW    = "";  // wi-day-snow
const MOON_SNOW   = "";  // wi-night-alt-snow
const SUN_STORM   = "";  // wi-day-thunderstorm
const MOON_STORM  = "";  // wi-night-alt-thunderstorm
const HAIL_STORM  = "";  // wi-storm-showers

// The furniture around the reading. Not all nf-weather: wi-thermometer and
// wi-strong-wind are thin and fussy next to a number, so the reading's own
// three glyphs come from the sets that draw them solid.
const GLYPH_SUNRISE  = "";
const GLYPH_SUNSET   = "";
const GLYPH_HUMIDITY = "";
const GLYPH_WIND     = "";
const GLYPH_THERMO   = "";
const GLYPH_UMBRELLA = "";
const GLYPH_REFRESH  = "";
const GLYPH_UNKNOWN  = "";  // wi-na

// code -> [day glyph, night glyph, label, palette role]
// The role is a name, not a colour: Zenon owns the palette, and weather.js is
// plain script with no access to it.
const CODES = {
  0:  [SUN, MOON, "Clear sky", "sun"],
  1:  [SUN_HAZE, MOON_HAZE, "Mainly clear", "sun"],
  2:  [SUN_CLOUD, MOON_HAZE, "Partly cloudy", "cloud"],
  3:  [OVERCAST, OVERCAST, "Overcast", "cloud"],
  45: [FOG, FOG, "Fog", "haze"],
  48: [FOG, FOG, "Freezing fog", "haze"],
  51: [SUN_SHOWERS, MOON_SHOWERS, "Light drizzle", "rain"],
  53: [SUN_SHOWERS, MOON_SHOWERS, "Drizzle", "rain"],
  55: [SUN_SHOWERS, MOON_SHOWERS, "Heavy drizzle", "rain"],
  56: [SUN_SLEET, MOON_SLEET, "Freezing drizzle", "sleet"],
  57: [SUN_SLEET, MOON_SLEET, "Freezing drizzle", "sleet"],
  61: [SUN_RAIN, MOON_RAIN, "Light rain", "rain"],
  63: [SUN_RAIN, MOON_RAIN, "Rain", "rain"],
  65: [SUN_RAIN, MOON_RAIN, "Heavy rain", "rain"],
  66: [SUN_SLEET, MOON_SLEET, "Freezing rain", "sleet"],
  67: [SUN_SLEET, MOON_SLEET, "Freezing rain", "sleet"],
  71: [SUN_SNOW, MOON_SNOW, "Light snow", "snow"],
  73: [SUN_SNOW, MOON_SNOW, "Snow", "snow"],
  75: [SUN_SNOW, MOON_SNOW, "Heavy snow", "snow"],
  77: [SUN_SNOW, MOON_SNOW, "Snow grains", "snow"],
  80: [SUN_SHOWERS, MOON_SHOWERS, "Light showers", "rain"],
  81: [SUN_SHOWERS, MOON_SHOWERS, "Showers", "rain"],
  82: [SUN_SHOWERS, MOON_SHOWERS, "Violent showers", "rain"],
  85: [SUN_SNOW, MOON_SNOW, "Snow showers", "snow"],
  86: [SUN_SNOW, MOON_SNOW, "Heavy snow showers", "snow"],
  95: [SUN_STORM, MOON_STORM, "Thunderstorm", "storm"],
  96: [HAIL_STORM, HAIL_STORM, "Thunderstorm, hail", "storm"],
  99: [HAIL_STORM, HAIL_STORM, "Thunderstorm, heavy hail", "storm"]
};

// The furniture glyphs, reachable by name for the same reason locateUrl() is a
// function: QML sees the functions in here, not the constants.
const ICONS = {
  sunrise: GLYPH_SUNRISE, sunset: GLYPH_SUNSET,
  humidity: GLYPH_HUMIDITY, wind: GLYPH_WIND, thermo: GLYPH_THERMO,
  umbrella: GLYPH_UMBRELLA, refresh: GLYPH_REFRESH, unknown: GLYPH_UNKNOWN
};

function icon(name) { return ICONS[name] ?? ""; }

function entry(code) {
  return CODES[code] ?? [GLYPH_UNKNOWN, GLYPH_UNKNOWN, "Unknown", "haze"];
}

function glyph(code, isDay) {
  const e = entry(code);
  return isDay ? e[0] : e[1];
}

function label(code) { return entry(code)[2]; }

function role(code) { return entry(code)[3]; }

// ── units ──────────────────────────────────────────────────────────────
// Fetched in celsius always and converted here, so flipping the unit is a
// display decision and never costs a round trip.
function toF(c) { return c * 9 / 5 + 32; }

function temp(c, fahrenheit) {
  if (c === null || c === undefined || isNaN(c)) return "--";
  return String(Math.round(fahrenheit ? toF(c) : c));
}

const COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

function windDir(deg) {
  if (deg === null || deg === undefined || isNaN(deg)) return "";
  return COMPASS[Math.round(((deg % 360) + 360) % 360 / 45) % 8];
}

// "13:41" out of open-meteo's "2026-08-29T13:41" — no Date round trip, since
// those stamps are already in the location's own timezone and parsing them
// would drag them into the host's
function hhmm(stamp) {
  const s = String(stamp ?? "");
  const t = s.indexOf("T");
  return t < 0 ? "" : s.slice(t + 1, t + 6);
}

// ── the request ────────────────────────────────────────────────────────
function forecastUrl(lat, lon) {
  return "https://api.open-meteo.com/v1/forecast"
    + "?latitude=" + encodeURIComponent(lat)
    + "&longitude=" + encodeURIComponent(lon)
    + "&current=temperature_2m,relative_humidity_2m,apparent_temperature"
    + ",is_day,weather_code,wind_speed_10m,wind_direction_10m"
    + "&hourly=temperature_2m,weather_code,precipitation_probability"
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
    + ",precipitation_probability_max,sunrise,sunset"
    + "&timezone=auto&forecast_days=7";
}

// ip-api over plain http: the free tier has no https, and this asks for a
// city and a coordinate pair and nothing else.
//
// A function rather than an exported const, like everything else reachable
// from QML here: a .js library hands the importer its top-level FUNCTIONS, and
// a `const` is not reliably one of them.
function locateUrl() {
  return "http://ip-api.com/json/?fields=status,lat,lon,city,country";
}

// ── parsing ────────────────────────────────────────────────────────────
// One shape out, whatever came in. Everything the panel binds to is present
// even on a half-empty payload, so a missing field is "--" rather than a
// TypeError halfway through building the pane.
function parseForecast(text) {
  const j = JSON.parse(text);
  if (!j || !j.current || !j.daily) throw new Error("no forecast in reply");

  const c = j.current;
  const current = {
    temp: c.temperature_2m,
    feels: c.apparent_temperature,
    humidity: c.relative_humidity_2m,
    wind: c.wind_speed_10m,
    windDeg: c.wind_direction_10m,
    code: c.weather_code,
    isDay: c.is_day !== 0,
    stamp: c.time ?? ""
  };

  const d = j.daily;
  const days = [];
  const times = d.time ?? [];
  for (let i = 0; i < times.length; ++i) {
    days.push({
      date: times[i],
      code: (d.weather_code ?? [])[i],
      hi: (d.temperature_2m_max ?? [])[i],
      lo: (d.temperature_2m_min ?? [])[i],
      pop: (d.precipitation_probability_max ?? [])[i],
      sunrise: (d.sunrise ?? [])[i] ?? "",
      sunset: (d.sunset ?? [])[i] ?? ""
    });
  }

  const h = j.hourly ?? {};
  const hours = [];
  const hTimes = h.time ?? [];
  for (let i = 0; i < hTimes.length; ++i) {
    hours.push({
      time: hTimes[i],
      temp: (h.temperature_2m ?? [])[i],
      code: (h.weather_code ?? [])[i],
      pop: (h.precipitation_probability ?? [])[i]
    });
  }

  return { current: current, days: days, hours: hours, fetched: Date.now() };
}

// The next `count` hourly samples from `stamp` onward. open-meteo hands back
// the whole run of days starting at midnight, so "now" is somewhere in the
// middle of it and the first entries are already in the past.
function hoursFrom(hours, stamp, count) {
  const from = String(stamp ?? "");
  let start = -1;
  for (let i = 0; i < hours.length; ++i) {
    if (String(hours[i].time) >= from) { start = i; break; }
  }
  // A reading newer than the whole hourly run means the payload has gone stale
  // — show its tail rather than silently rewinding to the first day, which
  // would present last week's midnight as the next twelve hours.
  if (start < 0) return hours.slice(Math.max(0, hours.length - count));
  return hours.slice(start, start + count);
}

// A Sparkline reads 0..100, so the run is normalized against its own extremes
// rather than against an absolute temperature scale — the shape of the next
// twelve hours is the point, not where it sits on a thermometer.
function normalize(values) {
  const nums = values.filter((v) => typeof v === "number" && !isNaN(v));
  if (nums.length < 2) return [];
  const lo = Math.min.apply(null, nums);
  const hi = Math.max.apply(null, nums);
  // a dead-flat run would divide by zero; draw it down the middle instead
  if (hi - lo < 0.01) return nums.map(() => 50);
  return nums.map((v) => ((v - lo) / (hi - lo)) * 88 + 6);
}
