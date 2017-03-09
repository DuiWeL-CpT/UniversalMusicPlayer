import android.content {
    Context
}
import android.media {
    MediaMetadata
}
import android.media.session {
    PlaybackState,
    MediaSession
}
import android.net {
    Uri
}

import com.example.android.uamp.model {
    customMetadataTrackSource,
    MusicProvider
}
import com.example.android.uamp.utils {
    MediaIDHelper,
    LogHelper
}
import com.google.android.gms.cast {
    MediaInfo,
    MediaStatus,
    MediaData=MediaMetadata
}
import com.google.android.gms.cast.framework {
    CastContext
}
import com.google.android.gms.cast.framework.media {
    RemoteMediaClient
}
import com.google.android.gms.common.images {
    WebImage
}

import java.util {
    Objects
}

import org.json {
    JSONObject,
    JSONException
}

shared class CastPlayback(MusicProvider musicProvider, Context context)
        satisfies Playback
        & RemoteMediaClient.Listener {

    value tag = LogHelper.makeLogTag(`CastPlayback`);

    value mimeTypeAudioMpeg = "audio/mpeg";
    value itemId = "itemId";

    function toCastMediaMetadata(MediaMetadata track, JSONObject customData) {
        value metadata = MediaData(MediaData.mediaTypeMusicTrack);
        metadata.putString(MediaData.keyTitle, track.description.title?.string else "");
        metadata.putString(MediaData.keySubtitle, track.description.subtitle?.string else "");
        metadata.putString(MediaData.keyAlbumArtist, track.getString(MediaMetadata.metadataKeyAlbumArtist));
        metadata.putString(MediaData.keyAlbumTitle, track.getString(MediaMetadata.metadataKeyAlbum));
        value image = WebImage(Uri.Builder().encodedPath(track.getString(MediaMetadata.metadataKeyAlbumArtUri)).build());
        metadata.addImage(image);
        metadata.addImage(image);
        return MediaInfo.Builder(track.getString(customMetadataTrackSource))
            .setContentType(mimeTypeAudioMpeg)
            .setStreamType(MediaInfo.streamTypeBuffered)
            .setMetadata(metadata)
            .setCustomData(customData)
            .build();
    }

    value appContext = context.applicationContext;

    value remoteMediaClient
            = CastContext.getSharedInstance(appContext)
        .sessionManager.currentCastSession
        .remoteMediaClient;

    variable Callback? callback = null;
    variable Integer currentPosition = 0;

    shared actual variable Integer state = 0;

    shared actual variable String? currentMediaId = null;

    shared actual void start() => remoteMediaClient.addListener(this);

    shared actual void stop(Boolean notifyListeners) {
        remoteMediaClient.removeListener(this);
        state = PlaybackState.stateStopped;
        if (notifyListeners) {
            callback?.onPlaybackStatusChanged(state);
        }
    }

    shared actual Integer currentStreamPosition
            => !connected then this.currentPosition
    else remoteMediaClient.approximateStreamPosition;

    assign currentStreamPosition
            => this.currentPosition = currentStreamPosition;

    shared actual void updateLastKnownStreamPosition()
            => currentPosition = currentStreamPosition;

    shared actual void play(MediaSession.QueueItem item) {
        try {
            assert (exists id = item.description.mediaId);
            loadMedia(id, true);
            state = PlaybackState.stateBuffering;
            callback?.onPlaybackStatusChanged(state);
        }
        catch (JSONException e) {
            LogHelper.e(tag, "Exception loading media ", e, null);
            callback?.onError(e.message);
        }
    }

    shared actual void pause() {
        try {
            if (remoteMediaClient.hasMediaSession()) {
                remoteMediaClient.pause();
                currentPosition = remoteMediaClient.approximateStreamPosition;
            } else {
                assert (exists id = currentMediaId);
                loadMedia(id, false);
            }
        }
        catch (JSONException e) {
//            LogHelper.e(tag, e, "Exception pausing cast playback");
            callback?.onError(e.message);
        }
    }

    shared actual void seekTo(Integer position) {
        if (exists id = currentMediaId) {
            try {
                if (remoteMediaClient.hasMediaSession()) {
                    remoteMediaClient.seek(position);
                    currentPosition = position;
                } else {
                    currentPosition = position;
                    loadMedia(id, false);
                }
            }
            catch (JSONException e) {
                //            LogHelper.e(tag, e, "Exception pausing cast playback");
                callback?.onError(e.message);
            }
        }
        else {
            callback?.onError("seekTo cannot be calling in the absence of mediaId.");
            return;
        }
    }

    shared actual void setCallback(Callback callback) => this.callback = callback;

    shared actual Boolean connected
            => CastContext.getSharedInstance(appContext)
        .sessionManager.currentCastSession
        ?.connected
    else false;

    shared actual Boolean playing => connected && remoteMediaClient.playing;

    void loadMedia(String mediaId, Boolean autoPlay) {
        value musicId = MediaIDHelper.extractMusicIDFromMediaID(mediaId);
        "Invalid mediaId ``mediaId``"
        assert (exists track = musicProvider.getMusic(musicId));
        if (!Objects.equals(mediaId, currentMediaId)) {
            currentMediaId = mediaId;
            currentPosition = 0;
        }
        value customData = JSONObject();
        customData.put(itemId, mediaId);
        value media = toCastMediaMetadata(track, customData);
        remoteMediaClient.load(media, autoPlay, currentPosition, customData);
    }


    void setMetadataFromRemote() {
        try {
            if (exists mediaInfo = remoteMediaClient.mediaInfo,
                exists customData = mediaInfo.customData, customData.has(itemId)) {
                value remoteMediaId = customData.getString(itemId);
                if (!Objects.equals(currentMediaId, remoteMediaId)) {
                    currentMediaId = remoteMediaId;
                    callback?.setCurrentMediaId(remoteMediaId);
                    updateLastKnownStreamPosition();
                }
            }
        }
        catch (JSONException e) {
//            LogHelper.e(tag, e, "Exception processing update metadata");
        }
    }

    void updatePlaybackState() {
        value status = remoteMediaClient.playerState;
        value idleReason = remoteMediaClient.idleReason;
        LogHelper.d(tag, "onRemoteMediaPlayerStatusUpdated ", status);
        if (status == MediaStatus.playerStateIdle) {
            if (idleReason == MediaStatus.idleReasonFinished) {
                callback?.onCompletion();
            }
        }
        else if (status == MediaStatus.playerStateBuffering) {
            state = PlaybackState.stateBuffering;
            callback?.onPlaybackStatusChanged(state);
        }
        else if (status == MediaStatus.playerStatePlaying) {
            state = PlaybackState.statePlaying;
            setMetadataFromRemote();
            callback?.onPlaybackStatusChanged(state);
        }
        else if (status == MediaStatus.playerStatePaused) {
            state = PlaybackState.statePaused;
            setMetadataFromRemote();
            callback?.onPlaybackStatusChanged(state);
        }
        else {
            LogHelper.d(tag, "State default : ", status);
        }
    }

    shared actual void onMetadataUpdated() {
        LogHelper.d(tag, "RemoteMediaClient.onMetadataUpdated");
        setMetadataFromRemote();
    }

    shared actual void onStatusUpdated() {
        LogHelper.d(tag, "RemoteMediaClient.onStatusUpdated");
        updatePlaybackState();
    }

    shared actual void onSendingRemoteMediaRequest() {}
    shared actual void onAdBreakStatusUpdated() {}
    shared actual void onQueueStatusUpdated() {}
    shared actual void onPreloadStatusUpdated() {}

}