// Safe to expose client-side: this is the anon/public key, restricted by
// Row Level Security policies on the `registrations` table (insert-only for
// anonymous visitors, read-only for logged-in admins). Never put the
// service role key here or in any other client-side file.
const SUPABASE_URL = "https://esydiawzpmtgnugpaodn.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVzeWRpYXd6cG10Z251Z3Bhb2RuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk2MjgwMzEsImV4cCI6MjEwNTIwNDAzMX0.v0RHWysgGmKwPrqK492L55U5vqROQqMtrGyPtvzht1o";
