/* One audio element; streams and artwork are loaded only when selected. */
(() => {
    const tracks = JSON.parse(document.getElementById('tracks').textContent);
    const player = document.getElementById('player');
    const tableBody = document.querySelector('#playlistTable tbody');
    const ids = ['currentTrack', 'currentArtist', 'currentAlbum', 'currentArtwork', 'artworkPlaceholder',
        'playbackState', 'playerStatus', 'elapsedTime', 'durationTime', 'seekControl', 'volumeControl',
        'volumeControls', 'volumeHint', 'muteButton', 'customControls', 'startButton', 'playPauseButton',
        'prevButton', 'nextButton', 'loopButton', 'shuffleButton'];
    const ui = Object.fromEntries(ids.map(id => [id, document.getElementById(id)]));
    const labels = { idle: 'No track selected', loading: 'Loading', playing: 'Playing', paused: 'Paused',
        buffering: 'Buffering', blocked: 'Press Play', error: 'Playback error', finished: 'Finished', unsupported: 'Unsupported browser' };
    const rowStates = [];
    let currentIndex = -1;
    let isLooping = false;
    let isShuffling = false;
    let hls;
    let selection = 0;
    let session;
    let state = 'idle';
    let seekSelection;
    let removeMediaListeners = () => {};

    // Retain the hls.js / ManagedMediaSource policy used by this application.
    player.disableRemotePlayback = true;

    function formatTime(seconds) {
        if (!Number.isFinite(seconds) || seconds < 0) return '--:--';
        const total = Math.floor(seconds);
        const minutes = Math.floor(total / 60);
        const remainder = String(total % 60).padStart(2, '0');
        return minutes >= 60 ? `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, '0')}:${remainder}` : `${minutes}:${remainder}`;
    }

    function activeMedia() {
        return session?.ready && session.id === selection && session.source === (player.currentSrc || player.src);
    }

    function renderProgress() {
        const ready = activeMedia() && !['error', 'unsupported', 'loading'].includes(state);
        const duration = ready ? player.duration : NaN;
        const valid = Number.isFinite(duration) && duration > 0;
        ui.durationTime.textContent = formatTime(valid ? duration : NaN);
        ui.seekControl.disabled = !valid || player.seekable.length === 0;
        ui.seekControl.max = valid ? duration : 0;
        if (seekSelection !== selection) {
            const elapsed = ready && Number.isFinite(player.currentTime) ? player.currentTime : 0;
            ui.elapsedTime.textContent = formatTime(elapsed);
            ui.seekControl.value = valid ? Math.min(duration, Math.max(0, elapsed)) : 0;
        }
    }

    function renderPlaybackState() {
        const selected = currentIndex >= 0;
        ui.playbackState.textContent = labels[state];
        ui.playPauseButton.textContent = state === 'error' ? 'Retry' : ['playing', 'buffering'].includes(state) ? 'Pause' : 'Play';
        ui.playPauseButton.disabled = !selected || ['loading', 'unsupported'].includes(state);
        ui.prevButton.disabled = !selected;
        ui.nextButton.disabled = !selected || (!(isShuffling && tracks.length > 1) && currentIndex === tracks.length - 1);
        ui.startButton.disabled = ui.loopButton.disabled = ui.shuffleButton.disabled = tracks.length === 0;
        [...tableBody.children].forEach((row, i) => {
            const active = i === currentIndex;
            row.classList.toggle('active', active);
            if (active) row.setAttribute('aria-current', 'true');
            else row.removeAttribute('aria-current');
            rowStates[i].textContent = active ? labels[state] : '';
        });
        renderProgress();
    }

    function setState(next, message = '') {
        state = next;
        ui.playerStatus.textContent = message;
        renderPlaybackState();
    }

    function streamError() {
        if (session) {
            session.ready = false;
            session.wantsPlay = false;
            session.attempt += 1;
        }
        player.pause();
        setState('error', 'Unable to load this stream. Press Retry or select another track.');
    }

    function requestPlay() {
        if (!activeMedia()) return;
        const current = session;
        const attempt = ++current.attempt;
        current.wantsPlay = true;
        player.play().catch(error => {
            if (current !== session || attempt !== current.attempt || !current.wantsPlay) return;
            current.wantsPlay = false;
            if (error.name === 'NotSupportedError') streamError();
            else setState('blocked', 'Playback could not start. Press Play to try again.');
        });
    }

    function renderCurrentTrack(track, selectionId) {
        ui.currentTrack.textContent = track.title || track.file;
        ui.currentArtist.textContent = track.artist || 'Artist information unavailable';
        ui.currentAlbum.textContent = track.album || 'Album information unavailable';
        ui.currentArtwork.hidden = true;
        ui.currentArtwork.removeAttribute('src');
        ui.artworkPlaceholder.hidden = false;
        if (!track.artwork_url) return;
        // Separate requests keep stale load/error events away from the visible image.
        const image = new Image();
        image.addEventListener('load', () => {
            if (selectionId !== selection) return;
            ui.currentArtwork.src = image.src;
            ui.currentArtwork.hidden = false;
            ui.artworkPlaceholder.hidden = true;
        });
        image.addEventListener('error', () => {
            if (selectionId !== selection) return;
            ui.currentArtwork.hidden = true;
            ui.artworkPlaceholder.hidden = false;
        });
        image.src = track.artwork_url;
    }

    function bindMedia(current) {
        const listeners = {
            playing: () => {
                if (player.paused || player.ended || !current.wantsPlay) return;
                setState('playing');
            },
            pause: () => {
                if (!player.paused || player.ended || ['error', 'blocked', 'finished'].includes(state)) return;
                current.wantsPlay = false;
                current.attempt += 1;
                setState('paused');
            },
            waiting: () => {
                if (!player.paused && current.wantsPlay) setState('buffering', 'Buffering audio…');
            },
            ended: () => {
                if (!player.ended || state === 'finished') return;
                current.wantsPlay = false;
                if (isLooping) playTrack(currentIndex);
                else if ((isShuffling && tracks.length > 1) || currentIndex < tracks.length - 1) nextTrack();
                else setState('finished', 'Playlist finished. Press Play all to restart.');
            },
            error: () => { if (player.error) streamError(); },
            loadedmetadata: renderProgress,
            durationchange: renderProgress,
            progress: renderProgress,
            timeupdate: renderProgress
        };
        const bound = Object.entries(listeners).map(([event, listener]) => {
            const guarded = () => {
                if (current === session && activeMedia()) listener();
            };
            player.addEventListener(event, guarded);
            return [event, guarded];
        });
        removeMediaListeners = () => bound.forEach(([event, listener]) => player.removeEventListener(event, listener));
    }

    function playTrack(index) {
        const track = tracks[index];
        if (!track) return;
        selection += 1;
        removeMediaListeners();
        session = undefined;
        player.pause();
        if (hls) hls.destroy();
        hls = undefined;
        player.removeAttribute('src');
        player.load();
        currentIndex = index;
        seekSelection = undefined;
        renderCurrentTrack(track, selection);
        const current = { id: selection, ready: false, source: undefined, wantsPlay: true, attempt: 0 };
        session = current;
        setState('loading', 'Loading track…');
        bindMedia(current);
        if (typeof Hls === 'undefined' || !Hls.isSupported()) {
            setState('unsupported', 'This browser cannot play HLS streams. Update your browser or reload the page to retry.');
            return;
        }
        hls = new Hls();
        hls.on(Hls.Events.MANIFEST_PARSED, () => {
            if (current !== session || state === 'error') return;
            current.ready = true;
            current.source = player.currentSrc || player.src;
            renderProgress();
            requestPlay();
        });
        hls.on(Hls.Events.ERROR, (_event, data) => {
            if (current === session && data.fatal) streamError();
        });
        hls.loadSource(track.url);
        hls.attachMedia(player);
    }

    function nextTrack() {
        if (currentIndex < 0) return;
        if (isShuffling && tracks.length > 1) {
            const offset = 1 + Math.floor(Math.random() * (tracks.length - 1));
            playTrack((currentIndex + offset) % tracks.length);
        } else if (currentIndex + 1 < tracks.length) playTrack(currentIndex + 1);
    }

    ui.startButton.addEventListener('click', () => playTrack(0));
    ui.playPauseButton.addEventListener('click', () => {
        if (ui.playPauseButton.disabled) return;
        if (['error', 'finished'].includes(state)) playTrack(currentIndex);
        else if (player.paused) requestPlay();
        else {
            session.wantsPlay = false;
            session.attempt += 1;
            player.pause();
        }
    });
    ui.nextButton.addEventListener('click', nextTrack);
    ui.prevButton.addEventListener('click', () => {
        if (currentIndex >= 0) playTrack((currentIndex + tracks.length - 1) % tracks.length);
    });
    ui.loopButton.addEventListener('click', () => {
        isLooping = !isLooping;
        ui.loopButton.textContent = `Repeat track: ${isLooping ? 'ON' : 'OFF'}`;
        ui.loopButton.setAttribute('aria-pressed', String(isLooping));
    });
    ui.shuffleButton.addEventListener('click', () => {
        isShuffling = !isShuffling;
        ui.shuffleButton.textContent = `Shuffle: ${isShuffling ? 'ON' : 'OFF'}`;
        ui.shuffleButton.setAttribute('aria-pressed', String(isShuffling));
        renderPlaybackState();
    });

    ui.seekControl.addEventListener('input', () => {
        if (ui.seekControl.disabled) return;
        seekSelection = selection;
        ui.elapsedTime.textContent = formatTime(Number(ui.seekControl.value));
    });
    ui.seekControl.addEventListener('change', () => {
        if (seekSelection !== selection || ui.seekControl.disabled) {
            seekSelection = undefined;
            renderProgress();
            return;
        }
        const desired = Number(ui.seekControl.value);
        const ranges = player.seekable;
        let nearest;
        for (let i = 0; i < ranges.length; i += 1) {
            const candidate = Math.max(ranges.start(i), Math.min(ranges.end(i), desired));
            if (nearest === undefined || Math.abs(candidate - desired) < Math.abs(nearest - desired)) nearest = candidate;
        }
        seekSelection = undefined;
        if (Number.isFinite(nearest)) player.currentTime = nearest;
        renderProgress();
    });
    ui.seekControl.addEventListener('blur', () => {
        seekSelection = undefined;
        renderProgress();
    });

    function renderVolume() {
        ui.volumeControl.value = player.volume;
        ui.muteButton.textContent = player.muted ? 'Unmute' : 'Mute';
        ui.muteButton.setAttribute('aria-pressed', String(player.muted));
    }
    // Some devices expose volume but do not allow scripts to change it.
    const originalVolume = player.volume;
    let canChangeVolume = false;
    try {
        const probe = originalVolume > 0.5 ? 0.25 : 0.75;
        player.volume = probe;
        canChangeVolume = player.volume === probe;
    } catch (_) {
        canChangeVolume = false;
    } finally {
        try { player.volume = originalVolume; } catch (_) { /* Device volume is read-only. */ }
    }
    ui.volumeControls.hidden = !canChangeVolume;
    ui.volumeHint.hidden = canChangeVolume;
    ui.volumeControl.addEventListener('input', () => { player.volume = Number(ui.volumeControl.value); });
    ui.muteButton.addEventListener('click', () => { player.muted = !player.muted; });
    player.addEventListener('volumechange', renderVolume);
    renderVolume();

    tracks.forEach((track, index) => {
        const row = document.createElement('tr');
        const playCell = document.createElement('td');
        const button = document.createElement('button');
        button.textContent = '▶';
        button.setAttribute('aria-label', `Play ${track.title || track.file}`);
        button.addEventListener('click', () => playTrack(index));
        playCell.dataset.label = 'Play';
        playCell.appendChild(button);
        row.appendChild(playCell);
        [[track.title || track.file, 'Title'], [track.artist || '', 'Artist'], [track.album || '', 'Album']].forEach(([text, label]) => {
            const cell = document.createElement('td');
            cell.textContent = text;
            cell.dataset.label = label;
            row.appendChild(cell);
        });
        const rowState = document.createElement('td');
        rowState.dataset.label = 'Status';
        rowState.classList.add('track-status');
        rowStates.push(rowState);
        row.appendChild(rowState);
        tableBody.appendChild(row);
    });
    setState('idle', tracks.length ? '' : 'No MP3 files found.');
    ui.customControls.hidden = false;
    player.controls = false;
    player.hidden = true;
})();
