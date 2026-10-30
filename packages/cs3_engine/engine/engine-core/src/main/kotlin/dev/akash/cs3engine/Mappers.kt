package dev.akash.cs3engine

import com.lagradost.cloudstream3.ActorData
import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.AnimeSearchResponse
import com.lagradost.cloudstream3.Episode
import com.lagradost.cloudstream3.EpisodeResponse
import com.lagradost.cloudstream3.LiveStreamLoadResponse
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.LoadResponse.Companion.getAniListId
import com.lagradost.cloudstream3.LoadResponse.Companion.getImdbId
import com.lagradost.cloudstream3.LoadResponse.Companion.getKitsuId
import com.lagradost.cloudstream3.LoadResponse.Companion.getMalId
import com.lagradost.cloudstream3.LoadResponse.Companion.getTMDbId
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MovieLoadResponse
import com.lagradost.cloudstream3.MovieSearchResponse
import com.lagradost.cloudstream3.Score
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.SimklSyncServices
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.TorrentLoadResponse
import com.lagradost.cloudstream3.TrailerData
import com.lagradost.cloudstream3.TvSeriesLoadResponse
import com.lagradost.cloudstream3.TvSeriesSearchResponse
import com.lagradost.cloudstream3.utils.DrmExtractorLink
import com.lagradost.cloudstream3.utils.ExtractorLink
import java.io.File

/** CloudStream model objects → plain maps for the JSON protocol. */
internal object Mappers {
    /**
     * Names CloudStream's id keys as its app does at start-up (mal, kitsu, anilist, simkl). The library's defaults are
     * empty, so without this every addMalId/addAniListId/addImdbId/addTMDbId wrote the one key "" and each overwrote
     * the last.
     */
    fun nameSyncKeys() {
        LoadResponse.malIdPrefix = "mal"
        LoadResponse.kitsuIdPrefix = "kitsu"
        LoadResponse.aniListIdPrefix = "anilist"
        LoadResponse.simklIdPrefix = "simkl"
    }

    fun provider(api: MainAPI): Map<String, Any?> = mapOf(
        "name" to api.name,
        "mainUrl" to api.mainUrl,
        "lang" to api.lang,
        "types" to api.supportedTypes.map { it.name },
        "hasMainPage" to api.hasMainPage,
        "sections" to api.mainPage.map { it.name }.filter { it.isNotBlank() },
        "plugin" to api.sourcePlugin?.let { File(it).nameWithoutExtension },
    )

    fun searchItem(item: SearchResponse): Map<String, Any?> = mapOf(
        "name" to item.name,
        "url" to item.url,
        "type" to item.type?.name,
        "posterUrl" to item.posterUrl,
        "posterHeaders" to item.posterHeaders,
        "year" to when (item) {
            is MovieSearchResponse -> item.year
            is TvSeriesSearchResponse -> item.year
            is AnimeSearchResponse -> item.year
            else -> null
        },
        // The extension that answered: CloudStream lists a title's recommendations from that extension only.
        "apiName" to item.apiName,
        "score" to score(item.score),
        "quality" to item.quality?.name,
    )

    fun loadResponse(response: LoadResponse): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>(
            "name" to response.name,
            "url" to response.url,
            "type" to response.type.name,
            "plot" to response.plot,
            "posterUrl" to response.posterUrl,
            "backgroundPosterUrl" to response.backgroundPosterUrl,
            "year" to response.year,
            "tags" to response.tags,
            "duration" to response.duration,
            "score" to score(response.score),
            "contentRating" to response.contentRating,
            "logoUrl" to response.logoUrl,
            "posterHeaders" to response.posterHeaders,
            "comingSoon" to response.comingSoon,
            "actors" to response.actors?.map(::actor),
            "trailers" to response.trailers.map(::trailer),
            "recommendations" to response.recommendations?.map(::searchItem),
            "syncIds" to syncIds(response),
        )
        if (response is EpisodeResponse) {
            out["showStatus"] = response.showStatus?.name
            // unixTime is in seconds.
            out["nextAiring"] = response.nextAiring?.let {
                mapOf("episode" to it.episode, "unixTime" to it.unixTime, "season" to it.season)
            }
            out["seasonNames"] = response.seasonNames?.map {
                mapOf("season" to it.season, "name" to it.name, "displaySeason" to it.displaySeason)
            }
        }
        when (response) {
            is MovieLoadResponse -> out["dataUrl"] = response.dataUrl
            is LiveStreamLoadResponse -> out["dataUrl"] = response.dataUrl
            is TvSeriesLoadResponse -> out["episodes"] = response.episodes.map { episode(it, null) }
            is AnimeLoadResponse -> out["episodes"] =
                response.episodes.flatMap { (dub, episodes) -> episodes.map { episode(it, dub.name) } }
            is TorrentLoadResponse -> {
                out["magnet"] = response.magnet
                out["torrent"] = response.torrent
            }
        }
        return out
    }

    private fun episode(episode: Episode, dub: String?): Map<String, Any?> = mapOf(
        "name" to episode.name,
        "season" to episode.season,
        "episode" to episode.episode,
        "data" to episode.data,
        "posterUrl" to episode.posterUrl,
        "description" to episode.description,
        "dub" to dub,
        "score" to score(episode.score),
        // Epoch milliseconds (an Anichi episode: 1736002800000).
        "date" to episode.date,
        // Minutes, as CloudStream shows it (its episode list multiplies by 60), though the library's docs say seconds.
        "runTime" to episode.runTime,
    )

    fun link(link: ExtractorLink): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>(
            "source" to link.source,
            "name" to link.name,
            "url" to link.url,
            "type" to link.type.name,
            "quality" to link.quality,
            "referer" to link.referer,
            "headers" to link.headers,
        )
        // The sound of a link that carries it in a file of its own: a YouTube download gives the
        // video and the audio apart, and the app plays the two together.
        val audio = link.audioTracks.orEmpty()
        if (audio.isNotEmpty()) {
            out["audioTracks"] = audio.map { track ->
                mapOf(
                    "url" to track.url,
                    "headers" to track.headers,
                )
            }
        }
        if (link is DrmExtractorLink) {
            out["drm"] = mapOf(
                "kid" to link.kid,
                "key" to link.key,
                "uuid" to link.uuid.toString(),
                "licenseUrl" to link.licenseUrl,
            )
        }
        return out
    }

    fun subtitle(subtitle: SubtitleFile): Map<String, Any?> = mapOf(
        "lang" to subtitle.lang,
        "url" to subtitle.url,
        "headers" to subtitle.headers,
    )

    /** A score out of ten; under 0.1 is none, as CloudStream hides it. Jackson would write a [Score] as {"data": …}. */
    private fun score(score: Score?): Double? = score?.toDouble(10)?.takeIf { it >= 0.1 }

    private fun actor(data: ActorData): Map<String, Any?> = mapOf(
        "name" to data.actor.name,
        "image" to data.actor.image,
        // Main, Supporting or Background, which the app translates; roleString is free text, shown as it is.
        "role" to data.role?.name,
        "roleString" to data.roleString,
        "voiceActor" to data.voiceActor?.let { mapOf("name" to it.name, "image" to it.image) },
    )

    private fun trailer(data: TrailerData): Map<String, Any?> = mapOf(
        "url" to data.extractorUrl,
        "referer" to data.referer,
        "raw" to data.raw,
        "headers" to data.headers,
    )

    /**
     * The title's ids elsewhere, under the keys SkyStream's trackers read. CloudStream keeps IMDb, TMDb and Simkl ids
     * (and copies of MAL and AniList) as one JSON text under its Simkl key, which the library's getters read. A
     * missing id can arrive as the text "null".
     */
    private fun syncIds(response: LoadResponse): Map<String, String> {
        val bundle = runCatching { LoadResponse.readIdFromString(response.syncData[LoadResponse.simklIdPrefix]) }
            .getOrDefault(emptyMap())
        val ids = listOf(
            "mal" to (response.getMalId() ?: bundle[SimklSyncServices.Mal]),
            "anilist" to (response.getAniListId() ?: bundle[SimklSyncServices.AniList]),
            "kitsu" to response.getKitsuId(),
            "simkl" to bundle[SimklSyncServices.Simkl],
            "imdb" to runCatching { response.getImdbId() }.getOrNull(),
            "tmdb" to runCatching { response.getTMDbId() }.getOrNull(),
        )
        return ids.mapNotNull { (key, id) -> id?.trim()?.takeIf { it.isNotEmpty() && it != "null" }?.let { key to it } }
            .toMap()
    }
}
