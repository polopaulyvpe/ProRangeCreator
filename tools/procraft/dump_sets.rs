
// Ajouté par ProRange Creator (outil de la CI, voir .github/workflows/procraft-brushes.yml) : écrit chaque jeu de pinceaux
// livré avec ProCraft en fichier .brushset (réglages, formes et grains dessinés par ProCraft), dans $PROCRANGE_DUMP.
#[cfg(test)]
mod procrange_dump {
    use crate::CanvasSession;

    #[test]
    #[ignore]
    fn dump_shipped_sets() {
        let Ok(out) = std::env::var("PROCRANGE_DUMP") else { return };
        let session = CanvasSession::new(64, 64);
        let mut index = 0u32;
        let mut list = String::new();
        while let Some((name, count)) = session.set_name_and_count(index) {
            if let Some(bytes) = session.brush_set_as_file(index) {
                let file = format!("{index:02}.brushset");
                std::fs::write(format!("{out}/{file}"), bytes).unwrap_or_default();
                list.push_str(&format!("{file}\t{name}\t{count}\n"));
            }
            index += 1;
        }
        std::fs::write(format!("{out}/sets.tsv"), list).unwrap_or_default();
    }
}
