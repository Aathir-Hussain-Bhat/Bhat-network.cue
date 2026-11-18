-- Add fields already captured by the frontend but omitted from the initial schema.
-- All additions are nullable and preserve existing rows and account roles.
ALTER TABLE public.workshops
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS postal_code text;

ALTER TABLE public.vehicles
  ADD COLUMN IF NOT EXISTS color text;
