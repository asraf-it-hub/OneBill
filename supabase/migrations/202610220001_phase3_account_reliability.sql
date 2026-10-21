-- Phase 3: account deletion hardening.
-- Account deletion is authenticated and bound to auth.uid() in the function.
-- Anonymous clients must never be allowed to execute it.
revoke execute on function public.delete_user_account() from anon;
grant execute on function public.delete_user_account() to authenticated, service_role;
notify pgrst, 'reload schema';
