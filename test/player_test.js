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
        this.classList = { toggle: (_name, active) => { this.active = active; } };
    }
    addEventListener(name, listener) {
        if (!this.listeners.has(name)) this.listeners.set(name, new Set());
        this.listeners.get(name).add(listener);
    }
    removeEventListener(name, listener) { this.listeners.get(name)?.delete(listener); }
    emit(name) { [...(this.listeners.get(name) || [])].forEach(listener => listener()); }
    appendChild(child) { this.children.push(child); }
    setAttribute(name, value) { this.attributes[name] = value; }
    set innerHTML(_value) { throw new Error('Track metadata must be assigned as text'); }
}

function setup({ native = true, support = true, tracks, rejectPlay = false } = {}) {
    tracks ||= [0, 1, 2].map(i => ({ file: `song${i}`, url: `/stream/song${i}/playlist.m3u8` }));
    const elements = Object.fromEntries(['tracks', 'player', 'currentTrack', 'playerStatus', 'startButton', 'playPauseButton', 'prevButton', 'nextButton', 'loopButton', 'shuffleButton'].map(id => [id, new Element()]));
    elements.tracks.textContent = JSON.stringify(tracks);
    ['playPauseButton', 'prevButton', 'nextButton'].forEach(id => { elements[id].disabled = true; });
    const tableBody = new Element();
    const player = elements.player;
    player.paused = true;
    player.loads = 0;
    player.plays = 0;
    player.canPlayType = () => native ? 'probably' : '';
    player.load = () => { player.loads += 1; };
    player.pause = () => { player.paused = true; };
    player.play = () => {
        player.plays += 1;
        if (rejectPlay) return Promise.reject(new Error('blocked'));
        player.paused = false;
        return Promise.resolve();
    };
    const instances = [];
    class Hls {
        static isSupported() { return support; }
        static Events = { MANIFEST_PARSED: 'ready', ERROR: 'error' };
        constructor() { this.listeners = {}; instances.push(this); }
        on(name, callback) { this.listeners[name] = callback; }
        loadSource(url) { this.url = url; }
        attachMedia(media) { this.media = media; }
        destroy() { this.destroyed = true; }
        emit(name, data) { this.listeners[name]?.(name, data); }
    }
    const context = {
        document: {
            getElementById: id => elements[id],
            querySelector: () => tableBody,
            createElement: () => new Element()
        },
        Hls: support ? Hls : undefined,
        Math: Object.assign(Object.create(Math), { random: () => 0 })
    };
    vm.runInNewContext(source, context);
    const click = id => elements[id].emit('click');
    const select = index => tableBody.children[index].children[0].children[0].emit('click');
    return { elements, tableBody, player, instances, click, select };
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

test('native HLS waits for canplay and removes superseded listeners', () => {
    const { player, elements, instances, click, select } = setup();
    click('startButton');
    assert.equal(player.src, '/stream/song0/playlist.m3u8');
    assert.equal(player.plays, 0);
    select(2);
    assert.equal(player.listeners.get('canplay').size, 1);
    player.emit('canplay');
    assert.equal(player.plays, 1);
    assert.equal(player.listeners.get('canplay').size, 0);
    assert.equal(elements.currentTrack.textContent, 'Now Playing: song2');
    assert.equal(instances.length, 0);
});

test('hls.js waits for the manifest and destroys the previous instance', () => {
    const { player, instances, click, select } = setup({ native: false });
    click('startButton');
    assert.equal(instances[0].url, '/stream/song0/playlist.m3u8');
    assert.equal(player.plays, 0);
    select(1);
    assert.equal(instances[0].destroyed, true);
    instances[0].emit('ready');
    assert.equal(player.plays, 0);
    instances[1].emit('ready');
    assert.equal(player.plays, 1);
});

test('continuous playback stops at the end and Play all restarts', () => {
    const { player, elements, tableBody, click } = setup();
    click('startButton');
    player.emit('ended');
    assert.equal(player.src, '/stream/song1/playlist.m3u8');
    player.emit('ended');
    assert.equal(player.src, '/stream/song2/playlist.m3u8');
    const loads = player.loads;
    player.emit('ended');
    assert.equal(player.loads, loads);
    assert.equal(tableBody.children.some(row => row.active), false);
    assert.match(elements.playerStatus.textContent, /Playlist finished/);
    click('startButton');
    assert.equal(player.src, '/stream/song0/playlist.m3u8');
});

test('previous, next, play/pause and repeat track have consistent behavior', () => {
    const { player, elements, click } = setup();
    click('startButton');
    player.emit('canplay');
    click('playPauseButton');
    assert.equal(player.paused, true);
    click('playPauseButton');
    assert.equal(player.paused, false);
    click('nextButton');
    assert.equal(player.src, '/stream/song1/playlist.m3u8');
    click('prevButton');
    assert.equal(player.src, '/stream/song0/playlist.m3u8');
    click('prevButton');
    assert.equal(player.src, '/stream/song2/playlist.m3u8');
    click('loopButton');
    assert.equal(elements.loopButton.attributes['aria-pressed'], 'true');
    player.emit('ended');
    assert.equal(player.src, '/stream/song2/playlist.m3u8');
    click('nextButton');
    assert.equal(player.src, '/stream/song2/playlist.m3u8');
});

test('shuffle selects a different track and single-track shuffle finishes', () => {
    const { player, click } = setup();
    click('startButton');
    click('shuffleButton');
    player.emit('ended');
    assert.equal(player.src, '/stream/song1/playlist.m3u8');
    const single = setup({ tracks: [{ file: 'only', url: '/only' }] });
    single.click('startButton');
    single.click('shuffleButton');
    single.player.emit('ended');
    assert.equal(single.player.loads, 1);
    assert.match(single.elements.playerStatus.textContent, /Playlist finished/);
});

test('unsupported HLS and fatal stream errors are visible', () => {
    const unsupported = setup({ native: false, support: false });
    unsupported.click('startButton');
    assert.match(unsupported.elements.playerStatus.textContent, /cannot play HLS/);
    assert.equal(unsupported.elements.playPauseButton.disabled, true);
    const fallback = setup({ native: false });
    fallback.click('startButton');
    fallback.instances[0].emit('error', { fatal: true });
    assert.match(fallback.elements.playerStatus.textContent, /Unable to load/);
});

test('rejected playback promises are handled and can be retried', async () => {
    const { player, elements, click } = setup({ rejectPlay: true });
    click('startButton');
    player.emit('canplay');
    await Promise.resolve();
    assert.match(elements.playerStatus.textContent, /Press Play to try again/);
    click('playPauseButton');
    assert.equal(player.plays, 2);
    await Promise.resolve();
});
