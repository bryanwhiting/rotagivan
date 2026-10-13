use std::ffi::{c_char, CStr};
struct Entry { name: String, id: String }
pub struct Index { entries: Vec<Entry> }
fn score(needle: &str, text: &str) -> Option<i32> {
    if needle == text { return Some(10000); }
    if text.starts_with(needle) { return Some(8000 - text.chars().count() as i32); }
    if text.contains(needle) { return Some(6000 - text.chars().count() as i32); }
    let mut chars = text.chars().enumerate().peekable();
    let mut previous = None; let mut last = ' '; let mut value = 1000;
    for wanted in needle.chars() {
        let mut found = false;
        while let Some((position, ch)) = chars.next() {
            if ch == wanted {
                if previous.map(|p| p + 1 == position).unwrap_or(false) { value += 60; }
                if position == 0 || !last.is_alphabetic() { value += 80; }
                previous = Some(position); last = ch; found = true; break;
            }
            value -= 1; last = ch;
        }
        if !found { return None; }
    }
    Some(value - text.chars().count() as i32)
}
fn search(index: &Index, query: &str, limit: usize) -> Vec<usize> {
    let tokens: Vec<_> = query.split_whitespace().collect();
    let mut matches: Vec<_> = index.entries.iter().enumerate().filter_map(|(i, entry)| {
        let mut total = 0;
        for token in &tokens {
            let best = score(token, &entry.name).into_iter().chain(score(token, &entry.id).map(|v| v - 250)).max()?;
            total += best;
        }
        Some((i, total))
    }).collect();
    matches.sort_unstable_by(|a,b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    matches.into_iter().take(limit).map(|v| v.0).collect()
}
#[no_mangle] pub extern "C" fn rota_index_new() -> *mut Index { Box::into_raw(Box::new(Index{entries:vec![]})) }
#[no_mangle] pub unsafe extern "C" fn rota_index_free(index: *mut Index) { if !index.is_null() { drop(Box::from_raw(index)); } }
#[no_mangle] pub unsafe extern "C" fn rota_index_add(index: *mut Index, name: *const c_char, id: *const c_char) {
    if index.is_null() || name.is_null() || id.is_null() { return; }
    if let (Ok(name), Ok(id)) = (CStr::from_ptr(name).to_str(), CStr::from_ptr(id).to_str()) {
        (*index).entries.push(Entry{name:name.to_owned(),id:id.to_owned()});
    }
}
#[no_mangle] pub unsafe extern "C" fn rota_index_search(index: *const Index, query: *const c_char, output: *mut usize, capacity: usize) -> usize {
    if index.is_null() || query.is_null() || output.is_null() { return 0; }
    let Ok(query) = CStr::from_ptr(query).to_str() else { return 0; };
    let hits = search(&*index, query, capacity);
    for (i, hit) in hits.iter().enumerate() { output.add(i).write(*hit); }
    hits.len()
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn ranking_unicode_duplicates() {
        let index = Index { entries: vec![Entry{name:"safari helper".into(),id:"a".into()},Entry{name:"safari".into(),id:"b".into()},Entry{name:"café 東京".into(),id:"c".into()},Entry{name:"safari".into(),id:"d".into()}] };
        assert_eq!(search(&index,"safari",8),vec![1,3,0]);
        assert_eq!(search(&index,"sfr",8),vec![1,3,0]);
        assert_eq!(search(&index,"東京",8),vec![2]);
        assert_eq!(search(&index,"café 東京",8),vec![2]);
        assert!(search(&index,"missing",8).is_empty());
        assert_eq!(search(&index,"",2),vec![0,1]);
    }
    #[test] fn benchmark() {
        let index = Index{entries:(0..2000).map(|i|Entry{name:format!("application chrome café {i}"),id:format!("com.example.{i}")}).collect()};
        let mut samples=vec![];
        for i in 0..1000 { let start=std::time::Instant::now(); std::hint::black_box(search(&index,["app","chrm","café","missing","1999"][i%5],12));samples.push(start.elapsed().as_micros()); }
        samples.sort(); println!("2000 entries, 1000 searches: median {}µs p95 {}µs max {}µs",samples[500],samples[950],samples[999]);
    }
}
