# Myata Memorial

## Локальная разработка
```sh
hugo -s myata serve -d public --baseURL http://127.0.0.1:1313/
```
## Продакшн-сборка
```sh
hugo -s myata --minify
```
## Сайт
[https://myata-memorial.github.io](https://myata-memorial.github.io)

## Перевод (с потерей правок)
```sh

cd myata

# Только разбивка на чанки (без API):
python3 scripts/translate.py --dry-run

# Полный перевод:
OPENAI_API_KEY=sk-... python3 scripts/translate.py

# С другой моделью:
OPENAI_API_KEY=sk-... OPENAI_MODEL=gpt-4o python3 scripts/translate.py

# Указать другой файл:
OPENAI_API_KEY=sk-... python3 scripts/translate.py --file content/_index.ru.md
```
