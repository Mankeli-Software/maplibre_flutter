/// The tile servers the engine knows the URL conventions of.
///
/// Named after Android's `WellKnownTileServer`; Apple spells the same idea
/// `+[MLNSettings useWellKnownTileServer:]`. Selecting one tells the engine how
/// to expand a short scheme URL (`maptiler://maps/streets`) and, crucially,
/// **where the api key goes**.
///
/// **Without one the api key does nothing.** That is not a subtlety of an edge
/// case — the engine reads the key on exactly one path, rewriting a URL under
/// the configured scheme, and three separate gates close it under the default:
/// an ordinary `https://…` URL is not canonical so it is returned untouched;
/// the default configuration declares that it requires no key; and its key
/// parameter name is empty. There is no `{key}` substitution anywhere either.
///
/// An app whose style URL is a plain `https://…` with the key already in the
/// query string needs none of this — that path never consults these options,
/// and stays exactly as it was. What it cannot do by hand is reach the sprite,
/// glyph and tile **sub-requests**, whose URLs come out of the style document
/// rather than from the app.
enum MapLibreTileServer {
  /// The engine's default: `demotiles.maplibre.org`, the `maplibre://` scheme,
  /// and **no api key** — this configuration declares it needs none, which is
  /// why a key set alongside it is inert.
  mapLibre,

  /// `api.maptiler.com`, the `maptiler://` scheme, key as `?key=`.
  mapTiler,

  /// `api.mapbox.com`, the `mapbox://` scheme, key as `?access_token=`.
  mapbox,
}
