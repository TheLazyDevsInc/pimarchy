// The Pimarchy download Worker (Cloudflare Workers). GitHub attaches a release's
// image in parts, since no release file may reach 2 GiB, and a tool that
// flashes from a URL (balenaEtcher's "Flash from URL") takes one file. This
// serves each release's image as one: it stores nothing, streams the parts from
// GitHub's release downloads joined in order, and answers a byte range by
// reading only the parts it covers, as a tool reading the xz index at the end
// of the image does.
//
//   /<tag>.img.xz            the image of the release with that tag
//   /<tag>.img.xz.sha256     its checksum, naming the image as its download
//                            does, as sha256sum -c and shasum -c read it
//   /<tag>.json              its manifest (pimarchy.json), with its tag
//   /latest.img.xz, ...      a redirect to the newest release's, so a client
//                            that reads the size and then the bytes reads one
//                            release's (balenaEtcher keeps the URL it lands on)
//
// Releases are found without GitHub's API, whose unauthenticated limit counts
// every Worker sharing an address: the repository's releases.atom feed lists
// the tags, newest first, and each release's pimarchy.json (pi/release-manifest)
// names its parts. REPO, in wrangler.toml, names the repository; GITHUB, unset
// there, points the tests at a stand-in for github.com.

const GITHUB = 'https://github.com'
// How long the feed and the manifests are cached, in seconds.
const FEED_TTL = 300
const MANIFEST_TTL = 300
// How many of the newest releases are tried for a manifest.
const RELEASES_TRIED = 10

// Tags and file names start with a letter or digit: no "." or ".." can make a
// download URL reach past a release's assets.
const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/
// GitHub asks every client to name itself.
const HEADERS = { 'User-Agent': 'pimarchy-download-worker' }

// The tags in the repository's releases.atom feed, newest first.
export function tagsFromFeed(xml, repo, origin = GITHUB) {
  const prefix = `${origin}/${repo}/releases/tag/`
  const tags = []
  for (const match of xml.matchAll(/<link[^>]*\shref="([^"]+)"/g)) {
    if (!match[1].startsWith(prefix)) continue
    let tag
    try {
      tag = decodeURIComponent(match[1].slice(prefix.length))
    } catch {
      continue
    }
    if (SAFE_NAME.test(tag) && !tags.includes(tag)) tags.push(tag)
  }
  return tags
}

// The manifest if it is one pi/release-manifest writes: names that need no
// escaping, and parts that add up to the image.
export function validManifest(manifest) {
  if (!manifest || manifest.format !== 1) return false
  const { image, size, sha256, image_size: imageSize, parts } = manifest
  if (typeof image !== 'string' || !SAFE_NAME.test(image) || !image.endsWith('.img.xz')) return false
  if (!Number.isSafeInteger(size) || size <= 0 || !Number.isSafeInteger(imageSize) || imageSize <= 0) return false
  if (typeof sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(sha256)) return false
  if (!Array.isArray(parts) || parts.length === 0) return false
  let total = 0
  for (const part of parts) {
    if (!part || typeof part.name !== 'string' || !SAFE_NAME.test(part.name)) return false
    if (!Number.isSafeInteger(part.size) || part.size <= 0) return false
    total += part.size
  }
  return total === size
}

// The one byte range a Range header asks for, as [start, end] inclusive; null
// to send the whole image (no header, or one this doesn't take, such as several
// ranges); 'unsatisfiable' for a range that starts past the end.
export function parseRange(header, size) {
  if (!header) return null
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim())
  if (!match || (match[1] === '' && match[2] === '')) return null
  if (match[1] === '') {
    const suffix = Number(match[2])
    if (suffix === 0) return 'unsatisfiable'
    return [Math.max(0, size - suffix), size - 1]
  }
  const start = Number(match[1])
  if (start >= size) return 'unsatisfiable'
  const end = match[2] === '' ? size - 1 : Math.min(Number(match[2]), size - 1)
  if (end < start) return null
  return [start, end]
}

// Which bytes of which parts make up bytes start to end of the image.
export function slices(parts, start, end) {
  const out = []
  let offset = 0
  for (const part of parts) {
    const first = offset
    const last = offset + part.size - 1
    offset += part.size
    if (last < start || first > end) continue
    out.push({ name: part.name, from: Math.max(start, first) - first, to: Math.min(end, last) - first, size: part.size })
  }
  return out
}

function downloadUrl(origin, repo, tag, name) {
  return `${origin}/${repo}/releases/download/${encodeURIComponent(tag)}/${name}`
}

// The text at url, cached for ttl seconds; null for a 404. Any other failure
// throws, so that GitHub having trouble reads as that, not as a missing file.
async function cachedText(url, ttl) {
  const response = await fetch(url, { headers: HEADERS, cf: { cacheTtl: ttl, cacheEverything: true } })
  if (response.status === 404) return null
  if (!response.ok) throw new Error(`GitHub answered ${response.status} for ${url}`)
  return response.text()
}

async function manifestFor(origin, repo, tag) {
  const text = await cachedText(downloadUrl(origin, repo, tag, 'pimarchy.json'), MANIFEST_TTL)
  if (text === null) return null
  let manifest
  try {
    manifest = JSON.parse(text)
  } catch {
    return null
  }
  return validManifest(manifest) ? manifest : null
}

// The release a path names, with its manifest: the newest one with a manifest
// for "latest", or the one with that tag.
async function findRelease(origin, repo, name) {
  if (name !== 'latest') {
    const manifest = await manifestFor(origin, repo, name)
    return manifest && { tag: name, manifest }
  }
  const feed = await cachedText(`${origin}/${repo}/releases.atom`, FEED_TTL)
  if (feed === null) throw new Error('GitHub did not send the releases feed')
  for (const tag of tagsFromFeed(feed, repo, origin).slice(0, RELEASES_TRIED)) {
    const manifest = await manifestFor(origin, repo, tag)
    if (manifest) return { tag, manifest }
  }
  return null
}

// Streams bytes start to end of the image into writable, part by part. A part
// that doesn't send exactly the bytes asked for ends the stream with an error,
// so the client sees a failed download rather than a wrong image.
async function pump(origin, repo, tag, manifest, start, end, writable) {
  try {
    for (const slice of slices(manifest.parts, start, end)) {
      const whole = slice.from === 0 && slice.to === slice.size - 1
      const response = await fetch(downloadUrl(origin, repo, tag, slice.name), {
        headers: whole ? HEADERS : { ...HEADERS, Range: `bytes=${slice.from}-${slice.to}` },
      })
      const length = Number(response.headers.get('Content-Length'))
      const ranged = response.status === 206 &&
        response.headers.get('Content-Range') === `bytes ${slice.from}-${slice.to}/${slice.size}`
      if (!(whole ? response.status === 200 || ranged : ranged) || length !== slice.to - slice.from + 1) {
        throw new Error(`GitHub sent ${slice.name} as ${response.status}, not bytes ${slice.from}-${slice.to}`)
      }
      await response.body.pipeTo(writable, { preventClose: true })
    }
    await writable.close()
  } catch (error) {
    await writable.abort(error).catch(() => {})
  }
}

function text(status, body, headers = {}) {
  return new Response(body, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8', ...headers } })
}

const HELP = (repo) => `Pimarchy images from https://github.com/${repo}/releases, each as one file.

/latest.img.xz          the newest release's image, for balenaEtcher's "Flash from URL"
/latest.img.xz.sha256   its checksum
/latest.json            its manifest
/<tag>.img.xz           a release's image by its tag (and .sha256, .json)

The latest ones redirect to the newest release's own.

On macOS and Linux, pi/flash in the repository writes it to a card and fills in pimarchy.txt.
`

export async function handle(request, env, ctx) {
  const repo = env.REPO
  const origin = env.GITHUB || GITHUB
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return text(405, 'Only GET and HEAD.\n', { Allow: 'GET, HEAD' })
  }
  let path
  try {
    path = decodeURIComponent(new URL(request.url).pathname)
  } catch {
    return text(400, 'That path is not one this can read.\n')
  }
  if (path === '/') return text(200, request.method === 'HEAD' ? null : HELP(repo))

  const match = /^\/([A-Za-z0-9][A-Za-z0-9._+-]*?)(\.img\.xz|\.img\.xz\.sha256|\.json)$/.exec(path)
  if (!match) return text(404, 'No such file. / lists what this serves.\n')
  const [, name, kind] = match

  let release
  try {
    release = await findRelease(origin, repo, name)
  } catch (error) {
    return text(502, `${error.message}. Try again in a minute.\n`)
  }
  if (!release) return text(404, `No release ${name === 'latest' ? 'has' : `${name} has`} a pimarchy.json manifest.\n`)
  const { tag, manifest } = release
  if (name === 'latest') {
    const location = new URL(`/${tag}${kind}`, request.url).toString()
    return new Response(null, { status: 302, headers: { Location: location, 'Cache-Control': 'no-store' } })
  }
  const body = (content) => (request.method === 'HEAD' ? null : content)

  if (kind === '.img.xz.sha256') return text(200, body(`${manifest.sha256}  ${manifest.image}\n`))
  if (kind === '.json') {
    return new Response(body(`${JSON.stringify({ tag, ...manifest }, null, 2)}\n`), {
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const size = manifest.size
  const etag = `"${manifest.sha256}"`
  // Only a GET takes a range; a HEAD describes the whole image.
  let range = request.method === 'GET' ? parseRange(request.headers.get('Range'), size) : null
  const ifRange = request.headers.get('If-Range')
  if (ifRange && ifRange !== etag) range = null
  if (range === 'unsatisfiable') return text(416, 'That range is past the end of the image.\n', { 'Content-Range': `bytes */${size}` })
  const [start, end] = range || [0, size - 1]
  const headers = {
    'Content-Type': 'application/x-xz',
    'Content-Length': String(end - start + 1),
    'Content-Disposition': `attachment; filename="${manifest.image}"`,
    'Accept-Ranges': 'bytes',
    ETag: etag,
  }
  if (range) headers['Content-Range'] = `bytes ${start}-${end}/${size}`
  const status = range ? 206 : 200
  // The runtime keeps a HEAD response's own Content-Length. A FixedLengthStream
  // left unread here would read as a Worker that hung, and fail the request.
  if (request.method === 'HEAD') return new Response(null, { status, headers })

  // A FixedLengthStream gives the response its Content-Length, and fails a body
  // of any other length. The Workers runtime pipes fetch bodies into it without
  // running JavaScript, so a long download costs no CPU time; elsewhere (in the
  // tests) a TransformStream stands in.
  const { readable, writable } = typeof FixedLengthStream === 'function'
    ? new FixedLengthStream(end - start + 1)
    : new TransformStream()
  const pumping = pump(origin, repo, tag, manifest, start, end, writable)
  if (ctx && typeof ctx.waitUntil === 'function') ctx.waitUntil(pumping)
  return new Response(readable, { status, headers })
}

export default {
  fetch: handle,
}
