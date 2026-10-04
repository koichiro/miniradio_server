/* One audio element; streams are loaded only when a track is selected. */
(() => {
    const tracks = JSON.parse(document.getElementById('tracks').textContent);
    const player = document.getElementById('player');
    const tableBody = document.querySelector('#playlistTable tbody');
    const currentTrack = document.getElementById('currentTrack');
    const status = document.getElementById('playerStatus');
    const startButton = document.getElementById('startButton');
    const playPauseButton = document.getElementById('playPauseButton');
    const prevButton = document.getElementById('prevButton');
    const nextButton = document.getElementById('nextButton');
    const loopButton = document.getElementById('loopButton');
    const shuffleButton = document.getElementById('shuffleButton');
    let currentIndex = -1;
    let isLooping = false;
    let isShuffling = false;
    let hls;
    let onCanPlay;
    let selection = 0;

    function reportError(message) {
        status.textContent = message;
    }

    function play(selectionId = selection) {
        player.play().catch(() => {
            if (selectionId === selection) reportError('Playback could not start. Press Play to try again.');
        });
    }

    function highlightTrack(index) {
        [...tableBody.children].forEach((row, i) => row.classList.toggle('active', i === index));
    }

    function playTrack(index) {
        const track = tracks[index];
        if (!track) return;

        selection += 1;
        const selectionId = selection;
        player.pause();
        if (onCanPlay) player.removeEventListener('canplay', onCanPlay);
        if (hls) {
            hls.destroy();
            hls = undefined;
        }
        currentIndex = index;
        highlightTrack(index);
        currentTrack.textContent = `Now Playing: ${track.title || track.file}`;
        status.textContent = '';
        playPauseButton.disabled = false;
        prevButton.disabled = false;
        nextButton.disabled = false;

        if (player.canPlayType('application/vnd.apple.mpegurl')) {
            onCanPlay = () => {
                player.removeEventListener('canplay', onCanPlay);
                onCanPlay = undefined;
                play(selectionId);
            };
            player.addEventListener('canplay', onCanPlay);
            player.src = track.url;
            player.load();
        } else if (typeof Hls !== 'undefined' && Hls.isSupported()) {
            hls = new Hls();
            hls.on(Hls.Events.MANIFEST_PARSED, () => {
                if (selectionId === selection) play(selectionId);
            });
            hls.on(Hls.Events.ERROR, (_event, data) => {
                if (selectionId === selection && data.fatal) reportError('Unable to load this stream. Select the track to retry.');
            });
            hls.loadSource(track.url);
            hls.attachMedia(player);
        } else {
            playPauseButton.disabled = true;
            reportError('This browser cannot play HLS streams.');
        }
    }

    function nextTrack() {
        if (tracks.length === 0 || currentIndex < 0) return;
        if (isShuffling && tracks.length > 1) {
            const offset = 1 + Math.floor(Math.random() * (tracks.length - 1));
            playTrack((currentIndex + offset) % tracks.length);
        } else if (currentIndex + 1 < tracks.length) {
            playTrack(currentIndex + 1);
        }
    }

    player.addEventListener('ended', () => {
        if (isLooping) playTrack(currentIndex);
        else if ((!isShuffling || tracks.length === 1) && currentIndex === tracks.length - 1) {
            highlightTrack(-1);
            status.textContent = 'Playlist finished. Press Play all to restart.';
        } else nextTrack();
    });
    player.addEventListener('error', () => reportError('Unable to load this stream. Select the track to retry.'));
    startButton.disabled = tracks.length === 0;
    loopButton.disabled = tracks.length === 0;
    shuffleButton.disabled = tracks.length === 0;
    if (tracks.length === 0) status.textContent = 'No MP3 files found.';

    startButton.addEventListener('click', () => playTrack(0));
    playPauseButton.addEventListener('click', () => {
        if (currentIndex < 0) return;
        if (player.paused) play();
        else player.pause();
    });
    nextButton.addEventListener('click', nextTrack);
    prevButton.addEventListener('click', () => {
        if (currentIndex >= 0) playTrack((currentIndex - 1 + tracks.length) % tracks.length);
    });
    loopButton.addEventListener('click', () => {
        isLooping = !isLooping;
        loopButton.textContent = `🔁 Repeat track: ${isLooping ? 'ON' : 'OFF'}`;
        loopButton.setAttribute('aria-pressed', String(isLooping));
    });
    shuffleButton.addEventListener('click', () => {
        isShuffling = !isShuffling;
        shuffleButton.textContent = `🔀 Shuffle: ${isShuffling ? 'ON' : 'OFF'}`;
        shuffleButton.setAttribute('aria-pressed', String(isShuffling));
    });

    tracks.forEach((track, index) => {
        const row = document.createElement('tr');
        const playCell = document.createElement('td');
        const button = document.createElement('button');
        button.textContent = '▶️';
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
        tableBody.appendChild(row);
    });
})();
