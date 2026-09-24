use serde_json::Value;
use std::{fs, path::PathBuf, sync::{Arc, RwLock}};

#[derive(Clone)]
pub struct RotaStore {
    path: PathBuf,
    state: Arc<RwLock<Option<Value>>>,
}

impl RotaStore {
    pub fn new(path: PathBuf) -> Self {
        let state = fs::read(&path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok());
        Self { path, state: Arc::new(RwLock::new(state)) }
    }

    pub fn get(&self) -> Result<Option<Value>, String> {
        self.state.read().map(|state| state.clone()).map_err(|error| error.to_string())
    }

    pub fn replace(&self, value: Value) -> Result<Value, String> {
        if !value.is_object() { return Err("Rota settings must be a JSON object".into()); }
        self.persist(&value)?;
        *self.state.write().map_err(|error| error.to_string())? = Some(value.clone());
        Ok(value)
    }

    pub fn set_pointer(&self, pointer: &str, value: Value) -> Result<Value, String> {
        if !pointer.starts_with('/') { return Err("JSON Pointer must start with /".into()); }
        let mut state = self.get()?.ok_or_else(|| "Rota has not initialized its settings yet".to_string())?;
        let target = state.pointer_mut(pointer).ok_or_else(|| format!("Setting path does not exist: {pointer}"))?;
        *target = value;
        self.replace(state)
    }

    pub fn delete_pointer(&self, pointer: &str) -> Result<Value, String> {
        if pointer.is_empty() || !pointer.starts_with('/') { return Err("Provide a non-root JSON Pointer".into()); }
        let mut state = self.get()?.ok_or_else(|| "Rota has not initialized its settings yet".to_string())?;
        let (parent_path, token) = pointer.rsplit_once('/').ok_or_else(|| "Invalid JSON Pointer".to_string())?;
        let token = token.replace("~1", "/").replace("~0", "~");
        let parent = if parent_path.is_empty() { &mut state } else {
            state.pointer_mut(parent_path).ok_or_else(|| format!("Parent path does not exist: {parent_path}"))?
        };
        match parent {
            Value::Object(map) => { map.remove(&token).ok_or_else(|| format!("Setting does not exist: {pointer}"))?; }
            Value::Array(items) => {
                let index: usize = token.parse().map_err(|_| "Array pointer must end in an index".to_string())?;
                if index >= items.len() { return Err(format!("Array index is out of range: {index}")); }
                items.remove(index);
            }
            _ => return Err("Parent setting is not an object or array".into()),
        }
        self.replace(state)
    }

    pub fn apply_patch(&self, patch: Value) -> Result<Value, String> {
        let operations: json_patch::Patch = serde_json::from_value(patch)
            .map_err(|error| format!("Invalid RFC 6902 patch: {error}"))?;
        let mut state = self.get()?.ok_or_else(|| "Rota has not initialized its settings yet".to_string())?;
        json_patch::patch(&mut state, &operations).map_err(|error| error.to_string())?;
        self.replace(state)
    }

    fn persist(&self, value: &Value) -> Result<(), String> {
        if let Some(directory) = self.path.parent() { fs::create_dir_all(directory).map_err(|error| error.to_string())?; }
        let temporary = self.path.with_extension("json.tmp");
        let encoded = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
        fs::write(&temporary, encoded).map_err(|error| error.to_string())?;
        fs::rename(temporary, &self.path).map_err(|error| error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn persists_pointer_edits_and_structural_patches() {
        let path = std::env::temp_dir().join(format!("rota-store-{}.json", std::process::id()));
        let _ = fs::remove_file(&path);
        let store = RotaStore::new(path.clone());
        store.replace(json!({"enabled": true, "profiles": [{"name": "Default"}]})).unwrap();
        store.set_pointer("/enabled", json!(false)).unwrap();
        store.apply_patch(json!([{"op": "add", "path": "/profiles/-", "value": {"name": "Studio"}}])).unwrap();
        assert_eq!(store.get().unwrap().unwrap()["enabled"], false);
        assert_eq!(store.get().unwrap().unwrap()["profiles"][1]["name"], "Studio");
        assert!(RotaStore::new(path.clone()).get().unwrap().is_some());
        let _ = fs::remove_file(path);
    }
}
