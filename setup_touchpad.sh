#!/bin/bash

BACKUP_FILE="$HOME/.touchpad_settings_backup"

# Function to detect the environment
get_de() {
    if [ "$XDG_CURRENT_DESKTOP" = "GNOME" ]; then echo "gnome";
    elif [ "$XDG_CURRENT_DESKTOP" = "KDE" ]; then echo "kde";
    elif [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then echo "hyprland";
    elif [ -n "$SWAYSOCK" ]; then echo "sway";
    else echo "unknown"; fi
}

apply_gnome() {
    echo "Applying GNOME optimizations..."
    # Backup current settings
    gsettings get org.gnome.desktop.peripherals.touchpad acceleration-profile > "$BACKUP_FILE"
    gsettings get org.gnome.desktop.peripherals.touchpad speed >> "$BACKUP_FILE"
    
    # Apply fluidity tweaks: Flat profile is essential for 1:1 feel
    gsettings set org.gnome.desktop.peripherals.touchpad acceleration-profile 'flat'
    gsettings set org.gnome.desktop.peripherals.touchpad speed 0.3
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
    echo "Done. For scroll speed, consider installing 'wayland-scroll-factor' from AUR."
}

apply_kde() {
    echo "Applying KDE Plasma optimizations..."
    # KDE uses kwriteconfig6 (Plasma 6) or kwriteconfig5
    CMD=$(command -v kwriteconfig6 || command -v kwriteconfig5)
    
    # Backup and set
    kreadconfig6 --file kcminputrc --group "Libinput" --key "PointerAccelerationProfile" >> "$BACKUP_FILE"
    
    $CMD --file kcminputrc --group "Libinput" --key "PointerAccelerationProfile" --type int 1 # 1 = Flat
    $CMD --file kcminputrc --group "Libinput" --key "NaturalScrolling" --type bool true
    echo "Restart your session to apply KDE changes fully."
}

apply_tiling() {
    DE=$1
    echo "Tiling WM ($DE) detected. Adding config snippets..."
    if [ "$DE" = "hyprland" ]; then
        echo -e "\ninput {\n    touchpad {\n        natural_scroll = true\n    }\n    accel_profile = flat\n}" >> ~/.config/hypr/hyprland.conf
    else
        echo "input \"type:touchpad\" { accel_profile flat; natural_scroll enabled; }" >> ~/.config/sway/config
    fi
    echo "Settings appended to your config. Reload with your WM shortcut."
}

revert_settings() {
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "No backup found. Manual reset required."
        return
    fi
    DE=$(get_de)
    case $DE in
        "gnome")
            VALS=($(cat "$BACKUP_FILE"))
            gsettings set org.gnome.desktop.peripherals.touchpad acceleration-profile "${VALS[0]}"
            gsettings set org.gnome.desktop.peripherals.touchpad speed "${VALS[1]}"
            ;;
        "kde")
            echo "Please use System Settings to reset Touchpad to 'Default'."
            ;;
    esac
    rm "$BACKUP_FILE"
    echo "Reverted."
}

# Main Logic
case "$1" in
    "--apply")
        DE=$(get_de)
        if [ "$DE" = "gnome" ]; then apply_gnome;
        elif [ "$DE" = "kde" ]; then apply_kde;
        elif [ "$DE" = "hyprland" ] || [ "$DE" = "sway" ]; then apply_tiling "$DE";
        else echo "Unsupported environment."; fi
        ;;
    "--revert")
        revert_settings
        ;;
    *)
        echo "Usage: $0 --apply | --revert"
        ;;
esac
