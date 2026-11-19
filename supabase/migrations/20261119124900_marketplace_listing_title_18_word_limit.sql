-- Keep marketplace listing titles concise at the database boundary as well as in the UI.
-- Empty tokens from leading, trailing, or repeated whitespace are ignored.
ALTER TABLE public.marketplace_listings
  ADD CONSTRAINT marketplace_listings_title_max_18_words
  CHECK (
    cardinality(
      array_remove(regexp_split_to_array(title, '[[:space:]]+'), '')
    ) BETWEEN 1 AND 18
  );
