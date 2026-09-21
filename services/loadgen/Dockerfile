FROM node:22-slim
WORKDIR /app
# No dependencies: the generator uses Node's built-in global fetch.
COPY package.json ./
COPY index.js ./
CMD ["node", "index.js"]
