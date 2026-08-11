/**
 * supabase-client.ts
 * ============================================================
 * Supabase client configuration for self-hosted instance
 * at aaryavtech.online
 *
 * Install:
 *   npm install @supabase/supabase-js
 *
 * Usage: Import `supabase` from this file in your components.
 * ============================================================
 */

import { createClient, RealtimeChannel } from '@supabase/supabase-js'

// ─── Self-hosted Supabase configuration ─────────────────────
// These values point to your self-hosted instance.
// ANON_KEY is safe to use in frontend code (it's publishable).
// NEVER use SERVICE_ROLE_KEY in frontend code.

const SUPABASE_URL = 'https://api.aaryavtech.online'
const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY_FROM_ENV'  // copy from .env ANON_KEY

// Create the Supabase client
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    // Store session in localStorage (default — fine for web apps)
    persistSession: true,
    // Auto-refresh JWT tokens before they expire
    autoRefreshToken: true,
    // Detect session in URL hash after email confirmation / OAuth redirect
    detectSessionInUrl: true,
  },
  realtime: {
    // Optional: custom WebSocket params
    params: {
      eventsPerSecond: 10,
    },
  },
})


// ─── Authentication Examples ─────────────────────────────────

/**
 * Sign up a new user with email + password.
 * With ENABLE_EMAIL_AUTOCONFIRM=true, user is logged in immediately.
 * With ENABLE_EMAIL_AUTOCONFIRM=false, user gets a confirmation email.
 */
export async function signUp(email: string, password: string) {
  const { data, error } = await supabase.auth.signUp({ email, password })
  if (error) throw error
  return data
}

/**
 * Sign in with email + password
 */
export async function signIn(email: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password,
  })
  if (error) throw error
  return data
}

/**
 * Sign out the current user
 */
export async function signOut() {
  const { error } = await supabase.auth.signOut()
  if (error) throw error
}

/**
 * Get the currently logged-in user (or null if not logged in)
 */
export async function getCurrentUser() {
  const { data: { user } } = await supabase.auth.getUser()
  return user
}

/**
 * Get current session (includes access token, refresh token, user)
 */
export async function getSession() {
  const { data: { session } } = await supabase.auth.getSession()
  return session
}

/**
 * Listen for auth state changes (login, logout, token refresh)
 */
export function onAuthStateChange(callback: (event: string, session: any) => void) {
  return supabase.auth.onAuthStateChange(callback)
}


// ─── Database Query Examples ─────────────────────────────────

/**
 * Fetch all rows from a table (applies RLS automatically)
 */
export async function getAll<T = any>(table: string): Promise<T[]> {
  const { data, error } = await supabase.from(table).select('*')
  if (error) throw error
  return data as T[]
}

/**
 * Fetch rows with filtering
 */
export async function getFiltered<T = any>(
  table: string,
  column: string,
  value: string | number
): Promise<T[]> {
  const { data, error } = await supabase
    .from(table)
    .select('*')
    .eq(column, value)
  if (error) throw error
  return data as T[]
}

/**
 * Insert a row
 */
export async function insertRow<T = any>(table: string, row: Partial<T>): Promise<T> {
  const { data, error } = await supabase
    .from(table)
    .insert(row)
    .select()
    .single()
  if (error) throw error
  return data as T
}

/**
 * Update a row by ID
 */
export async function updateRow<T = any>(
  table: string,
  id: string | number,
  updates: Partial<T>
): Promise<T> {
  const { data, error } = await supabase
    .from(table)
    .update(updates)
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data as T
}

/**
 * Delete a row by ID
 */
export async function deleteRow(table: string, id: string | number) {
  const { error } = await supabase
    .from(table)
    .delete()
    .eq('id', id)
  if (error) throw error
}


// ─── Realtime Subscription Examples ──────────────────────────

/**
 * Subscribe to all changes on a table (INSERT, UPDATE, DELETE).
 *
 * Requirements:
 *   1. Enable Realtime in Supabase Studio → Database → Replication
 *   2. Add your table to the replication publication
 *   3. The table must have RLS configured appropriately
 *
 * Example use case: ride tracking, driver status, admin dashboards
 */
export function subscribeToTable(
  table: string,
  onInsert?: (record: any) => void,
  onUpdate?: (record: any) => void,
  onDelete?: (record: any) => void
): RealtimeChannel {
  const channel = supabase
    .channel(`realtime-${table}`)
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table },
      (payload) => {
        console.log(`[Realtime] INSERT on ${table}:`, payload.new)
        onInsert?.(payload.new)
      }
    )
    .on(
      'postgres_changes',
      { event: 'UPDATE', schema: 'public', table },
      (payload) => {
        console.log(`[Realtime] UPDATE on ${table}:`, payload.new)
        onUpdate?.(payload.new)
      }
    )
    .on(
      'postgres_changes',
      { event: 'DELETE', schema: 'public', table },
      (payload) => {
        console.log(`[Realtime] DELETE on ${table}:`, payload.old)
        onDelete?.(payload.old)
      }
    )
    .subscribe((status) => {
      console.log(`[Realtime] Channel status for ${table}:`, status)
    })

  return channel
}

/**
 * Unsubscribe from a realtime channel
 */
export async function unsubscribe(channel: RealtimeChannel) {
  await supabase.removeChannel(channel)
}

/**
 * Broadcast example — for presence (who's online) and custom events
 * Useful for: driver location updates, typing indicators, etc.
 */
export function createBroadcastChannel(channelName: string) {
  return supabase.channel(channelName)
}


// ─── Storage Examples ─────────────────────────────────────────

/**
 * Upload a file to Supabase Storage
 */
export async function uploadFile(
  bucket: string,
  path: string,
  file: File
): Promise<string> {
  const { error } = await supabase.storage
    .from(bucket)
    .upload(path, file, { upsert: true })
  if (error) throw error

  // Return public URL
  const { data } = supabase.storage.from(bucket).getPublicUrl(path)
  return data.publicUrl
}

/**
 * Download / get public URL for a file
 */
export function getFileUrl(bucket: string, path: string): string {
  const { data } = supabase.storage.from(bucket).getPublicUrl(path)
  return data.publicUrl
}


// ─── Example: React Hook for realtime ride tracking ──────────
/*
import { useEffect, useState } from 'react'
import { supabase, subscribeToTable, unsubscribe } from './supabase-client'

type Driver = {
  id: string
  name: string
  status: 'available' | 'busy' | 'offline'
  lat: number
  lng: number
  updated_at: string
}

export function useDriverTracking() {
  const [drivers, setDrivers] = useState<Driver[]>([])

  useEffect(() => {
    // Initial fetch
    supabase.from('drivers').select('*').then(({ data }) => {
      if (data) setDrivers(data)
    })

    // Realtime subscription — update driver list on changes
    const channel = subscribeToTable(
      'drivers',
      // onInsert
      (newDriver) => setDrivers((prev) => [...prev, newDriver]),
      // onUpdate
      (updatedDriver) => setDrivers((prev) =>
        prev.map((d) => (d.id === updatedDriver.id ? updatedDriver : d))
      ),
      // onDelete
      (deletedDriver) => setDrivers((prev) =>
        prev.filter((d) => d.id !== deletedDriver.id)
      )
    )

    return () => { unsubscribe(channel) }
  }, [])

  return drivers
}
*/
