//! Game facts for the game page: credits (director, producer, composer…) from Wikidata, and an
//! introduction and a few anecdotes from the game's Wikipedia article, in the UI language when the
//! article exists in it. Fetched in the background on first view, cached in the database (30 days;
//! a miss is retried after a day). Only the game's name and year leave the machine.

use crate::state::Shared;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;

const FRESH_SECS: i64 = 30 * 86_400;
const RETRY_SECS: i64 = 86_400;
static IN_FLIGHT: Mutex<Option<HashSet<String>>> = Mutex::new(None);

/// Credits taken from Wikidata: (field, property).
const CREDITS: &[(&str, &str)] = &[
    ("developer", "P178"),
    ("publisher", "P123"),
    ("director", "P57"),
    ("producer", "P162"),
    ("designer", "P287"),
    ("composer", "P86"),
    ("series", "P179"),
];

fn key(game: &crate::db::GameRow, lang: &str) -> String {
    format!(
        "{}|{lang}",
        if game.group_key.is_empty() {
            game.name.to_lowercase()
        } else {
            game.group_key.clone()
        }
    )
}

/// Facts for a game: the cached ones, or `{"status":"loading"}` while they are fetched
/// (an event `{"type":"facts","rom_id":…}` follows).
pub fn get(app: &Shared, rom_id: i64, lang: &str) -> Value {
    let Some(game) = app.db.game(rom_id) else {
        return json!({ "status": "none" });
    };
    let lang = if lang.len() == 2 && lang.chars().all(|c| c.is_ascii_lowercase()) {
        lang
    } else {
        "en"
    };
    let k = key(&game, lang);
    let cached = app.db.facts(&k);
    if let Some((text, at)) = &cached {
        let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
        let age = crate::db::now() - at;
        let found = v["status"] == "ok";
        if (found && age < FRESH_SECS) || (!found && age < RETRY_SECS) {
            return v;
        }
    }
    {
        let mut guard = IN_FLIGHT.lock().unwrap();
        let set = guard.get_or_insert_with(HashSet::new);
        if !set.insert(k.clone()) {
            return json!({ "status": "loading" });
        }
    }
    let app2 = app.clone();
    let lang = lang.to_string();
    let (name, year) = (game.name.clone(), game.year);
    std::thread::spawn(move || {
        let result = fetch(&name, year, &lang);
        let v = match result {
            Ok(v) => v,
            Err(e) => {
                app2.db.log("facts", &format!("{name}: {e}"));
                json!({ "status": "none", "error": e })
            }
        };
        app2.db.set_facts(&k, &v.to_string());
        IN_FLIGHT
            .lock()
            .unwrap()
            .get_or_insert_with(HashSet::new)
            .remove(&k);
        app2.emit(json!({ "type": "facts", "rom_id": rom_id }));
    });
    // A stale answer is better than nothing while the new one is fetched.
    cached
        .and_then(|(t, _)| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({ "status": "loading" }))
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .tls_config(crate::romm::tls())
        .timeout_connect(Some(Duration::from_secs(8)))
        .timeout_global(Some(Duration::from_secs(20)))
        .user_agent(format!(
            "Borne/{} (https://github.com/Lightmaster00/borne)",
            crate::update::VERSION
        ))
        .build()
        .into()
}

fn get_json(agent: &ureq::Agent, url: &str) -> Result<Value, String> {
    let mut resp = agent
        .get(url)
        .call()
        .map_err(|e| format!("unreachable ({e})"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let body = resp
        .body_mut()
        .with_config()
        .limit(8 << 20)
        .read_to_vec()
        .map_err(|e| e.to_string())?;
    serde_json::from_slice(&body).map_err(|e| e.to_string())
}

fn enc(s: &str) -> String {
    crate::romm::percent_encode(s)
}

/// Lowercase letters and digits only, for comparing titles.
fn norm(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(|c| c.to_lowercase())
        .collect()
}

fn claim_ids(entity: &Value, prop: &str) -> Vec<String> {
    entity["claims"][prop]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| {
                    c["mainsnak"]["datavalue"]["value"]["id"]
                        .as_str()
                        .map(String::from)
                })
                .collect()
        })
        .unwrap_or_default()
}

fn claim_years(entity: &Value, prop: &str) -> Vec<i64> {
    entity["claims"][prop]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| c["mainsnak"]["datavalue"]["value"]["time"].as_str())
                .filter_map(|t| {
                    t.trim_start_matches('+')
                        .get(0..4)
                        .and_then(|y| y.parse().ok())
                })
                .collect()
        })
        .unwrap_or_default()
}

fn label(entity: &Value, lang: &str) -> Option<String> {
    entity["labels"][lang]["value"]
        .as_str()
        .or_else(|| entity["labels"]["en"]["value"].as_str())
        .map(String::from)
}

/// Best video game among the search candidates: must be a video game (Q7889); then the title
/// matches, then the release year.
pub fn choose_entity<'a>(
    entities: &'a Value,
    name: &str,
    year: Option<i64>,
    lang: &str,
) -> Option<&'a Value> {
    let want = norm(name);
    let mut best: Option<(i64, &Value)> = None;
    for (_, e) in entities.as_object()?.iter() {
        if !claim_ids(e, "P31").iter().any(|i| i == "Q7889") {
            continue;
        }
        let names: Vec<String> = [label(e, lang), label(e, "en")]
            .into_iter()
            .flatten()
            .map(|l| norm(&l))
            .collect();
        let mut score = 0;
        if names.iter().any(|l| *l == want) {
            score += 10;
        } else if names
            .iter()
            .any(|l| l.contains(&want) || want.contains(l.as_str()))
        {
            score += 4;
        } else {
            continue;
        }
        if let Some(y) = year {
            if claim_years(e, "P577").contains(&y) {
                score += 5;
            }
        }
        if best.map(|(s, _)| score > s).unwrap_or(true) {
            best = Some((score, e));
        }
    }
    best.map(|(_, e)| e)
}

/// Splits a plain-text Wikipedia extract (`== Title ==` markers) into the intro and sections.
pub fn sections(text: &str) -> (String, Vec<(String, String)>) {
    let mut intro = String::new();
    let mut out: Vec<(String, String)> = vec![];
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with("==") && t.ends_with("==") && t.len() > 4 {
            out.push((t.trim_matches('=').trim().to_string(), String::new()));
        } else if let Some((_, body)) = out.last_mut() {
            body.push_str(line);
            body.push('\n');
        } else {
            intro.push_str(line);
            intro.push('\n');
        }
    }
    (intro.trim().to_string(), out)
}

/// Section titles worth mining for anecdotes, in the languages Borne speaks and a few more.
const ANECDOTE_SECTIONS: &[&str] = &[
    "development",
    "production",
    "design",
    "music",
    "legacy",
    "reception",
    "trivia",
    "release",
    "développement",
    "conception",
    "musique",
    "postérité",
    "héritage",
    "accueil",
    "anecdotes",
    "sortie",
    "entwicklung",
    "musik",
    "rezeption",
    "nachwirkung",
    "desarrollo",
    "música",
    "legado",
    "recepción",
    "sviluppo",
    "musica",
    "accoglienza",
    "eredità",
];

/// A short first part of a paragraph: two sentences at most, 300 characters at most.
fn excerpt(p: &str) -> String {
    let p = p.trim();
    let mut end = 0;
    let mut sentences = 0;
    let bytes: Vec<(usize, char)> = p.char_indices().collect();
    for (k, (i, c)) in bytes.iter().enumerate() {
        if (*c == '.' || *c == '!' || *c == '?')
            && bytes
                .get(k + 1)
                .map(|(_, n)| n.is_whitespace())
                .unwrap_or(true)
        {
            sentences += 1;
            end = i + c.len_utf8();
            if sentences == 2 || end > 220 {
                break;
            }
        }
    }
    let mut s = if end == 0 {
        p.to_string()
    } else {
        p[..end].to_string()
    };
    if s.chars().count() > 300 {
        let cut: String = s.chars().take(299).collect();
        s = format!("{}…", cut.rsplit_once(' ').map(|(a, _)| a).unwrap_or(&cut));
    }
    s
}

pub fn anecdotes(parts: &[(String, String)], max: usize) -> Vec<String> {
    let mut out = vec![];
    for (title, body) in parts {
        let t = title.to_lowercase();
        if !ANECDOTE_SECTIONS.iter().any(|w| t.contains(w)) {
            continue;
        }
        for p in body
            .split('\n')
            .map(str::trim)
            .filter(|p| p.chars().count() >= 80 && !p.starts_with("=="))
        {
            out.push(excerpt(p));
            break; // one per section: variety over depth
        }
        if out.len() >= max {
            break;
        }
    }
    out
}

fn fetch(name: &str, year: Option<i64>, lang: &str) -> Result<Value, String> {
    let a = agent();
    let search = get_json(
        &a,
        &format!(
            "https://www.wikidata.org/w/api.php?action=wbsearchentities&format=json&type=item&limit=8&language={lang}&uselang={lang}&search={}",
            enc(name)
        ),
    )?;
    let ids: Vec<String> = search["search"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x["id"].as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    if ids.is_empty() {
        return Err("no Wikidata entry".into());
    }
    let entities = get_json(
        &a,
        &format!(
            "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=claims%7Clabels%7Csitelinks&languages={lang}%7Cen&ids={}",
            ids.join("%7C")
        ),
    )?;
    let entity = choose_entity(&entities["entities"], name, year, lang)
        .ok_or("no video game matches this title")?;
    let qid = entity["id"].as_str().unwrap_or_default().to_string();

    // Credits: resolve the people and companies to labels in one call.
    let mut wanted: Vec<String> = vec![];
    for (_, p) in CREDITS {
        for id in claim_ids(entity, p).into_iter().take(4) {
            if !wanted.contains(&id) {
                wanted.push(id);
            }
        }
    }
    let mut credits = serde_json::Map::new();
    if !wanted.is_empty() {
        let labels = get_json(
            &a,
            &format!(
                "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=labels&languages={lang}%7Cen&ids={}",
                wanted.iter().take(50).cloned().collect::<Vec<_>>().join("%7C")
            ),
        )?;
        for (field, p) in CREDITS {
            let names: Vec<String> = claim_ids(entity, p)
                .iter()
                .take(4)
                .filter_map(|id| label(&labels["entities"][id], lang))
                .collect();
            if !names.is_empty() {
                credits.insert(field.to_string(), json!(names));
            }
        }
    }
    let years = claim_years(entity, "P577");

    // Article: in the UI language when it exists, otherwise in English.
    let (wiki_lang, title) = [lang, "en"]
        .iter()
        .find_map(|l| {
            entity["sitelinks"][format!("{l}wiki")]["title"]
                .as_str()
                .map(|t| (l.to_string(), t.to_string()))
        })
        .unzip();
    let mut summary = String::new();
    let mut facts = vec![];
    let mut url = Value::Null;
    if let (Some(wl), Some(t)) = (wiki_lang.clone(), title) {
        let page = get_json(
            &a,
            &format!(
                "https://{wl}.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&prop=extracts&explaintext=1&exsectionformat=wiki&redirects=1&titles={}",
                enc(&t)
            ),
        )?;
        let text = page["query"]["pages"][0]["extract"]
            .as_str()
            .unwrap_or_default();
        let (intro, parts) = sections(text);
        summary = intro
            .split('\n')
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .take(2)
            .collect::<Vec<_>>()
            .join("\n\n");
        if summary.chars().count() > 900 {
            summary = format!("{}…", summary.chars().take(899).collect::<String>());
        }
        facts = anecdotes(&parts, 4);
        url = json!(format!(
            "https://{wl}.wikipedia.org/wiki/{}",
            enc(&t.replace(' ', "_"))
        ));
    }
    Ok(json!({
        "status": "ok",
        "wikidata": qid,
        "credits": credits,
        "release_years": years,
        "summary": summary,
        "anecdotes": facts,
        "wikipedia": url,
        "lang": wiki_lang,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entity(id: &str, label: &str, video_game: bool, year: &str) -> Value {
        json!({
            "id": id,
            "labels": { "en": { "value": label } },
            "claims": {
                "P31": [{ "mainsnak": { "datavalue": { "value": { "id": if video_game { "Q7889" } else { "Q5" } } } } }],
                "P577": [{ "mainsnak": { "datavalue": { "value": { "time": format!("+{year}-03-11T00:00:00Z") } } } }]
            }
        })
    }

    #[test]
    fn picks_the_video_game_with_the_right_title_and_year() {
        let all = json!({
            "Q1": entity("Q1", "Chrono Trigger", false, "1995"),
            "Q2": entity("Q2", "Chrono Trigger", true, "2008"),
            "Q3": entity("Q3", "Chrono Trigger", true, "1995"),
            "Q4": entity("Q4", "Something else", true, "1995"),
        });
        assert_eq!(
            choose_entity(&all, "Chrono Trigger", Some(1995), "fr").unwrap()["id"],
            "Q3"
        );
        assert_eq!(choose_entity(&all, "Unknown Game", Some(1995), "fr"), None);
    }

    #[test]
    fn mines_sections_for_short_anecdotes() {
        let text = "Intro paragraph one.\nIntro two.\n== Gameplay ==\nNot mined because gameplay is not an anecdote section at all, even if long enough.\n== Development ==\nThe team was formed in 1993 from three studios that had never worked together before. The director later said it was chaos. A third sentence that should be cut.\n== Legacy ==\nShort.\nThe game inspired a generation of developers and was re-released on several consoles over the following decades.\n";
        let (intro, parts) = sections(text);
        assert!(intro.starts_with("Intro paragraph one."));
        let a = anecdotes(&parts, 4);
        assert_eq!(a.len(), 2, "{a:?}");
        assert!(a[0].ends_with("it was chaos."), "{}", a[0]);
        assert!(a[1].starts_with("The game inspired"));
    }

    #[test]
    fn long_excerpts_are_cut_on_a_word() {
        let p = "word ".repeat(100);
        let e = excerpt(&p);
        assert!(e.chars().count() <= 300 && e.ends_with('…'));
    }
}
