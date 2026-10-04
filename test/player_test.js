const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../lib/public/player.js'), 'utf8');

class Element {
    constructor() {
        this.children = [];
        this.listeners = new Map();
        this.attributes = {};
        this.dataset = {};
        this.textContent = '';
        this.disabled = false;
        this.active = false;
        this.classList = { toggle: (_name, active) => { this.active = active; }, add: () => {} };
        this.value = 0;
        this.hidden = false;
    }
    addEventListener(name, listener) {
        if (!this.listeners.has(name)) this.listeners.set(name, new Set());
        this.listeners.get(name).add(listener);
    }
    removeEventListener(name, listener) { this.listeners.get(name)?.delete(listener); }
    emit(name) { [...(this.listeners.get(name) || [])].forEach(listener => listener()); }
    appendChild(child) { this.children.push(child); }
    setAttribute(name, value) { this.attributes[name] = value; }
    removeAttribute(name) { delete this.attributes[name]; if (name === 'src') this.src = undefined; }
    set innerHTML(_value) { throw new Error('Track metadata must be assigned as text'); }
}

function setup({ native = true, support = true, library = true, tracks, rejectPlay = false, readOnlyVolume = false, deferredPlay = false } = {}) {
    tracks ||= [0, 1, 2].map(i => ({ file: `song${i}`, url: `/stream/song${i}/playlist.m3u8` }));
    const elements = Object.fromEntries(['tracks', 'player', 'currentTrack', 'playerStatus', 'startButton', 'playPauseButton', 'prevButton', 'nextButton', 'loopButton', 'shuffleButton', 'currentArtist', 'currentAlbum', 'currentArtwork', 'artworkPlaceholder', 'playbackState', 'elapsedTime', 'durationTime', 'seekControl', 'volumeControl', 'volumeControls', 'volumeHint', 'muteButton', 'customControls'].map(id => [id, new Element()]));
    elements.tracks.textContent = JSON.stringify(tracks);
    ['playPauseButton', 'prevButton', 'nextButton'].forEach(id => { elements[id].disabled = true; });
    const tableBody = new Element();
    const player = elements.player;
    player.paused = true;
    player.ended = false;
    player.error = null;
    player.currentTime = 0;
    player.duration = NaN;
    player.seekable = { length: 0 };
    player.volume = 1;
    player.muted = false;
    if (readOnlyVolume) Object.defineProperty(player, 'volume', { get: () => 1, set: () => { throw new Error('read-only'); } });
    player.loads = 0;
    player.plays = 0;
    player.canPlayType = () => native ? 'probably' : '';
    player.load = () => { player.loads += 1; player.currentTime = 0; player.duration = NaN; player.seekable = { length: 0 }; player.ended = false; player.error = null; };
    player.pause = () => { player.paused = true; player.emit('pause'); };
    const pendingPlays = [];
    player.play = () => {
        player.plays += 1;
        if (rejectPlay) return Promise.reject(new Error('blocked'));
        if (deferredPlay) return new Promise((resolve, reject) => pendingPlays.push({ resolve, reject }));
        player.paused = false;
        player.ended = false;
        player.emit('playing');
        return Promise.resolve();
    };
    const instances = [];
    class Hls {
        static isSupported() { return support; }
        static Events = { MANIFEST_PARSED: 'ready', ERROR: 'error' };
        constructor() { this.listeners = {}; instances.push(this); }
        on(name, callback) { this.listeners[name] = callback; }
        loadSource(url) { this.url = url; }
        attachMedia(media) { this.media = media; media.src = `blob:${instances.length}`; }
        destroy() { this.destroyed = true; }
        emit(name, data) { this.listeners[name]?.(name, data); }
    }
    const images = [];
    class Image extends Element { constructor() { super(); images.push(this); } }
    const context = {
        Image,
        document: {
            getElementById: id => elements[id],
            querySelector: () => tableBody,
            createElement: () => new Element()
        },
        Hls: library ? Hls : undefined,
        Math: Object.assign(Object.create(Math), { random: () => 0 })
    };
    vm.runInNewContext(source, context);
    const click = id => elements[id].emit('click');
    const select = index => tableBody.children[index].children[0].children[0].emit('click');
    const ready = () => instances.at(-1).emit('ready');
    const ended = () => { player.ended = true; player.paused = true; player.emit('ended'); };
    return { elements, tableBody, player, instances, click, select, images, ready, ended, pendingPlays };
}

test('does not load streams before selection and renders metadata as text', () => {
    const title = '<img src=x onerror=alert(1)>';
    const { player, tableBody } = setup({ tracks: [{ title, file: 'song', url: '/song' }] });
    assert.equal(player.loads, 0);
    assert.equal(player.plays, 0);
    assert.equal(tableBody.children[0].children[1].textContent, title);
    assert.equal(tableBody.children[0].children[0].children[0].attributes['aria-label'], `Play ${title}`);
});

test('empty library disables controls without loading a stream', () => {
    const { elements, player, click } = setup({ tracks: [] });
    ['startButton', 'playPauseButton', 'prevButton', 'nextButton', 'loopButton', 'shuffleButton'].forEach(id => assert.equal(elements[id].disabled, true));
    click('startButton');
    click('nextButton');
    click('prevButton');
    assert.equal(player.loads, 0);
    assert.equal(elements.playerStatus.textContent, 'No MP3 files found.');
});

test('native HLS support still uses hls.js and enables ManagedMediaSource playback', () => {
    const { player, instances, click } = setup({ native: true });
    click('startButton');
    assert.equal(player.disableRemotePlayback, true);
    assert.equal(instances[0].media, player);
    assert.match(player.src, /^blob:/);
    assert.equal(player.loads, 1);
    player.emit('canplay');
    assert.equal(player.plays, 0);
    instances[0].emit('ready');
    assert.equal(player.plays, 1);
});

test('hls.js waits for the manifest and destroys the previous instance', () => {
    const { player, elements, instances, click, select } = setup({ native: false });
    click('startButton');
    assert.equal(instances[0].url, '/stream/song0/playlist.m3u8');
    assert.equal(player.plays, 0);
    select(1);
    assert.equal(instances[0].destroyed, true);
    instances[0].emit('ready');
    instances[0].emit('error', { fatal: true });
    assert.equal(player.plays, 0);
    assert.equal(elements.playerStatus.textContent, 'Loading track…');
    instances[1].emit('ready');
    assert.equal(player.plays, 1);
});

test('continuous playback stops at the end and Play all restarts', () => {
    const { player, elements, tableBody, instances, click, ready, ended } = setup();
    click('startButton');
    ready();
    ended();
    assert.equal(instances.at(-1).url, '/stream/song1/playlist.m3u8');
    ready();
    ended();
    assert.equal(instances.at(-1).url, '/stream/song2/playlist.m3u8');
    const loads = instances.length;
    ready();
    ended();
    assert.equal(instances.length, loads);
    assert.equal(tableBody.children[2].active, true);
    assert.equal(tableBody.children[2].attributes['aria-current'], 'true');
    assert.match(elements.playerStatus.textContent, /Playlist finished/);
    click('startButton');
    assert.equal(instances.at(-1).url, '/stream/song0/playlist.m3u8');
});

test('previous, next, play/pause and repeat track have consistent behavior', () => {
    const { player, elements, instances, click, ready, ended } = setup();
    click('startButton');
    instances[0].emit('ready');
    click('playPauseButton');
    assert.equal(player.paused, true);
    click('playPauseButton');
    assert.equal(player.paused, false);
    click('nextButton');
    assert.equal(instances.at(-1).url, '/stream/song1/playlist.m3u8');
    click('prevButton');
    assert.equal(instances.at(-1).url, '/stream/song0/playlist.m3u8');
    click('prevButton');
    assert.equal(instances.at(-1).url, '/stream/song2/playlist.m3u8');
    click('loopButton');
    assert.equal(elements.loopButton.attributes['aria-pressed'], 'true');
    ready();
    ended();
    assert.equal(instances.at(-1).url, '/stream/song2/playlist.m3u8');
    click('nextButton');
    assert.equal(instances.at(-1).url, '/stream/song2/playlist.m3u8');
});

test('shuffle selects a different track and single-track shuffle finishes', () => {
    const { player, instances, click, ready, ended } = setup();
    click('startButton');
    click('shuffleButton');
    ready();
    ended();
    assert.equal(instances.at(-1).url, '/stream/song1/playlist.m3u8');
    const single = setup({ tracks: [{ file: 'only', url: '/only' }] });
    single.click('startButton');
    single.click('shuffleButton');
    single.ready();
    single.ended();
    assert.equal(single.instances.length, 1);
    assert.match(single.elements.playerStatus.textContent, /Playlist finished/);
});

test('unsupported or missing hls.js never falls back to native HLS', () => {
    for (const options of [{ support: false }, { library: false }]) {
        const { player, elements, instances, click } = setup({ native: true, ...options });
        click('startButton');
        assert.match(elements.playerStatus.textContent, /cannot play HLS streams/);
        assert.equal(elements.playPauseButton.disabled, true);
        assert.equal(instances.length, 0);
        assert.equal(player.src, undefined);
        assert.equal(player.loads, 1);
        assert.equal(player.plays, 0);
    }
});

test('fatal stream errors are visible and reselecting retries with a new instance', () => {
    const { elements, instances, click, select } = setup();
    click('startButton');
    instances[0].emit('error', { fatal: false });
    assert.equal(elements.playerStatus.textContent, 'Loading track…');
    instances[0].emit('error', { fatal: true });
    assert.match(elements.playerStatus.textContent, /Unable to load/);
    select(0);
    assert.equal(instances[0].destroyed, true);
    assert.equal(instances.length, 2);
    assert.equal(elements.playerStatus.textContent, 'Loading track…');
});

test('Japanese and reserved characters in stream URLs reach hls.js unchanged', () => {
    const file = '日本語の曲 +%';
    const url = `/stream/${encodeURIComponent(file)}/playlist.m3u8`;
    const { player, elements, instances, click } = setup({ tracks: [{ file, url }] });
    click('startButton');
    assert.equal(instances[0].url, url);
    assert.equal(elements.currentTrack.textContent, file);
    instances[0].emit('ready');
    assert.equal(player.plays, 1);
});

test('rejected playback promises are handled and can be retried', async () => {
    const { player, elements, instances, click } = setup({ rejectPlay: true });
    click('startButton');
    instances[0].emit('ready');
    await Promise.resolve();
    assert.match(elements.playerStatus.textContent, /Press Play to try again/);
    click('playPauseButton');
    assert.equal(player.plays, 2);
    await Promise.resolve();
});

test('shared details, missing metadata and selected row stay synchronized', () => {
    const { elements, tableBody, select, ready, click } = setup({ tracks: [
        { title: '<b>Title</b>', artist: 'Artist', album: 'Album', file: 'one', url: '/one' },
        { file: 'two', url: '/two' }
    ] });
    assert.equal(elements.customControls.hidden, false);
    assert.equal(elements.player.controls, false);
    select(0);
    assert.equal(elements.currentTrack.textContent, '<b>Title</b>');
    assert.equal(elements.currentArtist.textContent, 'Artist');
    assert.equal(elements.currentAlbum.textContent, 'Album');
    assert.equal(elements.playbackState.textContent, 'Loading');
    ready();
    assert.equal(tableBody.children[0].children[4].textContent, 'Playing');
    click('playPauseButton');
    assert.equal(tableBody.children[0].children[4].textContent, 'Paused');
    select(1);
    assert.equal(elements.currentTrack.textContent, 'two');
    assert.match(elements.currentArtist.textContent, /unavailable/);
    assert.match(elements.currentAlbum.textContent, /unavailable/);
    assert.equal(tableBody.children[0].attributes['aria-current'], undefined);
    assert.equal(tableBody.children[1].attributes['aria-current'], 'true');
});

test('artwork loads only on selection and stale image responses cannot overwrite the current track', () => {
    const { elements, images, select } = setup({ tracks: [
        { file: 'one', url: '/one', artwork_url: '/artwork/one' },
        { file: 'two', url: '/two', artwork_url: '/artwork/two' }
    ] });
    assert.equal(images.length, 0);
    select(0);
    assert.equal(images[0].src, '/artwork/one');
    select(1);
    images[1].emit('load');
    assert.equal(elements.currentArtwork.src, '/artwork/two');
    assert.equal(elements.artworkPlaceholder.hidden, true);
    images[0].emit('load');
    images[0].emit('error');
    assert.equal(elements.currentArtwork.src, '/artwork/two');
    assert.equal(elements.currentArtwork.hidden, false);
    select(0);
    assert.equal(elements.currentArtwork.hidden, true);
    images[2].emit('error');
    assert.equal(elements.artworkPlaceholder.hidden, false);
});

test('duration and seek availability follow media events, preserving a drag preview', () => {
    const { elements, player, select, ready } = setup();
    select(0);
    ready();
    for (const duration of [NaN, Infinity, 0]) {
        player.duration = duration;
        player.emit('durationchange');
        assert.equal(elements.durationTime.textContent, '--:--');
        assert.equal(elements.seekControl.disabled, true);
    }
    player.duration = 3723;
    player.currentTime = 63;
    player.emit('loadedmetadata');
    assert.equal(elements.durationTime.textContent, '1:02:03');
    assert.equal(elements.elapsedTime.textContent, '1:03');
    assert.equal(elements.seekControl.disabled, true);
    player.seekable = { length: 2, start: i => [10, 80][i], end: i => [40, 100][i] };
    player.emit('progress');
    assert.equal(elements.seekControl.disabled, false);
    elements.seekControl.value = 70;
    elements.seekControl.emit('input');
    assert.equal(elements.elapsedTime.textContent, '1:10');
    player.currentTime = 65;
    player.emit('timeupdate');
    assert.equal(elements.seekControl.value, 70);
    elements.seekControl.emit('change');
    assert.equal(player.currentTime, 80);
    assert.equal(elements.elapsedTime.textContent, '1:20');
    select(1);
    assert.equal(elements.elapsedTime.textContent, '0:00');
    assert.equal(elements.durationTime.textContent, '--:--');
    elements.seekControl.emit('change');
    assert.equal(player.currentTime, 0);
});

test('state is driven by actual playback, not the Play button or stale events', async () => {
    const { player, elements, select, ready, pendingPlays } = setup({ deferredPlay: true });
    select(0);
    ready();
    assert.equal(elements.playbackState.textContent, 'Loading');
    const oldPlaying = [...player.listeners.get('playing')][0];
    select(1);
    oldPlaying();
    player.emit('playing');
    player.emit('ended');
    player.emit('error');
    assert.equal(elements.playbackState.textContent, 'Loading');
    pendingPlays[0].reject(new Error('old error'));
    await Promise.resolve();
    assert.equal(elements.playbackState.textContent, 'Loading');
    ready();
    player.paused = false;
    player.emit('playing');
    assert.equal(elements.playbackState.textContent, 'Playing');
    player.emit('pause'); // queued old pause, but the current media is playing
    assert.equal(elements.playbackState.textContent, 'Playing');
    player.emit('waiting');
    assert.equal(elements.playbackState.textContent, 'Buffering');
    player.pause();
    player.emit('waiting');
    assert.equal(elements.playbackState.textContent, 'Paused');
});

test('fatal errors retry the stream, while finished Play restarts the last selected track', () => {
    const { player, elements, instances, click, select, ready, ended } = setup();
    select(1);
    ready();
    player.error = { code: 3 };
    player.emit('error');
    assert.equal(elements.playPauseButton.textContent, 'Retry');
    click('playPauseButton');
    assert.equal(instances.at(-1).url, '/stream/song1/playlist.m3u8');
    assert.equal(instances.length, 2);
    select(2);
    ready();
    ended();
    assert.equal(elements.nextButton.disabled, true);
    assert.equal(elements.playbackState.textContent, 'Finished');
    click('playPauseButton');
    assert.equal(instances.at(-1).url, '/stream/song2/playlist.m3u8');
    assert.equal(elements.playbackState.textContent, 'Loading');
    click('shuffleButton');
    assert.equal(elements.nextButton.disabled, false);
});

test('volume and mute persist across track selection, with a device-control fallback', () => {
    const { player, elements, select } = setup();
    assert.equal(elements.volumeControls.hidden, false);
    elements.volumeControl.value = 0.3;
    elements.volumeControl.emit('input');
    assert.equal(player.volume, 0.3);
    elements.muteButton.emit('click');
    player.emit('volumechange');
    assert.equal(player.muted, true);
    assert.equal(elements.muteButton.textContent, 'Unmute');
    select(0);
    select(1);
    assert.equal(player.volume, 0.3);
    assert.equal(player.muted, true);
    const readOnly = setup({ readOnlyVolume: true });
    assert.equal(readOnly.elements.volumeControls.hidden, true);
    assert.equal(readOnly.elements.volumeHint.hidden, false);
    assert.equal(readOnly.elements.customControls.hidden, false);
});
