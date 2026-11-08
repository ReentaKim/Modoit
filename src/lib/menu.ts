/** macOS 네이티브 우클릭 메뉴 */
import { CheckMenuItem, Menu, MenuItem, PredefinedMenuItem } from "@tauri-apps/api/menu";

export type MenuEntry =
  | { label: string; action: () => void; enabled?: boolean; checked?: boolean }
  | "-";

export async function popupMenu(entries: MenuEntry[]) {
  const items = await Promise.all(
    entries.map((e) =>
      e === "-"
        ? PredefinedMenuItem.new({ item: "Separator" })
        : e.checked !== undefined
          ? CheckMenuItem.new({ text: e.label, checked: e.checked, enabled: e.enabled ?? true, action: e.action })
          : MenuItem.new({ text: e.label, enabled: e.enabled ?? true, action: e.action }),
    ),
  );
  const menu = await Menu.new({ items });
  await menu.popup();
}
