/* Celestia installer slideshow, shown while the system is being installed. */

import QtQuick 2.15
import calamares.slideshow 1.0

Presentation {
    id: presentation

    readonly property color textColor: "#e5e1e7"
    readonly property color mutedColor: "#c8c5d1"
    readonly property color accentColor: "#c2c1ff"

    Timer {
        interval: 12000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Image {
        anchors.fill: parent
        source: "generated/slide-background.png"
        fillMode: Image.PreserveAspectCrop
        z: -1
    }

    component InfoSlide: Slide {
        id: slide
        property string heading
        property string message

        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width * 0.8, 820)
            spacing: 24

            Text {
                width: parent.width
                text: slide.heading
                color: presentation.accentColor
                font.pixelSize: 40
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            Text {
                width: parent.width
                text: slide.message
                color: presentation.mutedColor
                font.pixelSize: 20
                lineHeight: 1.35
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.StyledText
            }
        }
    }

    InfoSlide {
        heading: "Добро пожаловать в Celestia"
        message: "Внутри — CachyOS: её ядро, драйверы и оптимизации.<br>Снаружи — оболочка caelestia на Hyprland."
    }

    InfoSlide {
        heading: "Выбор системы при включении"
        message: "Через 5 секунд по умолчанию загрузится Windows.<br>"
            + "Стрелками ← → выбери Celestia и нажми Enter."
    }

    InfoSlide {
        heading: "Вход"
        message: "Сразу после загрузки — экран блокировки Celestia.<br>Введи пароль, и ты на рабочем столе."
    }

    InfoSlide {
        heading: "Горячие клавиши"
        message: "<b>Super</b> — меню приложений &nbsp;·&nbsp; <b>Super+T</b> — терминал<br>"
            + "<b>Super+W</b> — браузер &nbsp;·&nbsp; <b>Super+E</b> — файлы<br>"
            + "<b>Super+Q</b> — закрыть окно &nbsp;·&nbsp; <b>Super+L</b> — блокировка<br>"
            + "<b>Alt+Shift</b> — сменить раскладку"
    }

    InfoSlide {
        heading: "Обновления"
        message: "Обновляй систему командой <b>celestia-update</b> в терминале:<br>"
            + "она обновит CachyOS и при необходимости пересоберёт оболочку."
    }

    function onActivate() { }
    function onLeave() { }
}
